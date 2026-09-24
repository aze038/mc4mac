'use strict';

// Loads Code.gs into a fresh V8 context with in-memory stand-ins for the Apps Script services it
// uses. The stand-ins behave like the real ones where Code.gs depends on it: Sheets refuses
// ranges outside the sheet and cells over 50,000 characters and treats a leading apostrophe as
// "text", the cache has Apps Script's size limits, and nothing touches the network.

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');

const CODE = fs.readFileSync(path.join(__dirname, '..', 'Code.gs'), 'utf8');
const SHEETS_MIME = 'application/vnd.google-apps.spreadsheet';
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

class Environment {
  constructor({ email = 'kamal@freightmasters.llc', now = '2026-09-24T08:00:00Z' } = {}) {
    this.email = email;
    this.logs = [];
    this.errors = [];
    this.triggers = [];
    this.lockAvailable = true;
    this.ids = 0;
    this.drive = new FakeDrive(this);
    this.spreadsheets = new Map();
    this.properties = new FakeProperties();
    this.cache = new FakeCache(this);

    this.context = vm.createContext({
      console: {
        log: (...parts) => this.logs.push(parts.join(' ')),
        warn: (...parts) => this.errors.push(parts.join(' ')),
        error: (...parts) => this.errors.push(parts.join(' ')),
      },
    });
    // Code.gs reads the time with `new Date()` and `Date.now()`; this clock lets tests move it.
    vm.runInContext(`(() => {
      const RealDate = Date;
      let now = RealDate.now();
      class ClockDate extends RealDate {
        constructor(...args) { if (args.length) super(...args); else super(now); }
        static now() { return now; }
      }
      globalThis.Date = ClockDate;
      globalThis.__setClock = ms => { now = ms; };
    })()`, this.context);
    this.setNow(now);
    Object.assign(this.context, this.services());
    vm.runInContext(CODE, this.context, { filename: 'Code.gs' });
  }

  nextId(prefix) {
    this.ids += 1;
    return prefix + '-' + String(this.ids).padStart(4, '0');
  }

  setNow(iso) {
    this.nowMs = Date.parse(iso);
    this.context.__setClock(this.nowMs);
  }

  advance(ms) {
    this.setNow(new Date(this.nowMs + ms).toISOString());
  }

  // A top-level constant or expression of Code.gs.
  value(expression) {
    return vm.runInContext(expression, this.context);
  }

  post(body) {
    const contents = typeof body === 'string' ? body : JSON.stringify(body);
    const output = this.context.doPost({ postData: { contents, type: 'text/plain', length: Buffer.byteLength(contents) } });
    assertJsonOutput(output);
    return JSON.parse(output.getContent());
  }

  get(parameter) {
    const output = this.context.doGet({ parameter });
    assertJsonOutput(output);
    return JSON.parse(output.getContent());
  }

  spreadsheetNamed(name) {
    for (const spreadsheet of this.spreadsheets.values()) {
      if (spreadsheet.getName() === name) return spreadsheet;
    }
    return null;
  }

  // A tab's rows as objects keyed by header, below the header row.
  table(spreadsheetName, tab) {
    const sheet = this.spreadsheetNamed(spreadsheetName).getSheetByName(tab);
    const lastRow = sheet.getLastRow();
    if (lastRow < 1) return [];
    const values = sheet.getRange(1, 1, lastRow, sheet.getLastColumn()).getValues();
    return values.slice(1).map(row => Object.fromEntries(values[0].map((header, i) => [header, row[i]])));
  }

  services() {
    const env = this;
    return {
      SpreadsheetApp: {
        create: name => {
          const spreadsheet = new FakeSpreadsheet(env, name);
          env.spreadsheets.set(spreadsheet.getId(), spreadsheet);
          return spreadsheet;
        },
        openById: id => {
          if (!env.spreadsheets.has(id)) throw new Error('Unable to open the file ' + id);
          return env.spreadsheets.get(id);
        },
        flush: () => {},
        newConditionalFormatRule: () => new Builder({ kind: 'conditionalFormat' }),
        newDataValidation: () => new Builder({ kind: 'dataValidation' }),
        WrapStrategy: { WRAP: 'WRAP', CLIP: 'CLIP', OVERFLOW: 'OVERFLOW' },
      },
      DriveApp: env.drive.api(),
      MimeType: { GOOGLE_SHEETS: SHEETS_MIME },
      PropertiesService: { getScriptProperties: () => env.properties },
      CacheService: { getScriptCache: () => env.cache },
      LockService: {
        getScriptLock: () => ({
          tryLock: () => env.lockAvailable,
          waitLock: () => {
            if (!env.lockAvailable) throw new Error('Lock timeout: another process was holding the lock for too long.');
          },
          releaseLock: () => {},
        }),
      },
      ContentService: {
        MimeType: { JSON: 'JSON', TEXT: 'TEXT' },
        createTextOutput: content => ({
          content,
          mimeType: 'TEXT',
          setMimeType(type) { this.mimeType = type; return this; },
          getContent() { return this.content; },
        }),
      },
      Session: { getEffectiveUser: () => ({ getEmail: () => env.email }) },
      Utilities: { getUuid: () => crypto.randomUUID(), formatDate },
      ScriptApp: {
        newTrigger: handler => triggerBuilder(env, handler),
        getProjectTriggers: () => env.triggers.slice(),
        deleteTrigger: trigger => { env.triggers = env.triggers.filter(t => t !== trigger); },
      },
      Logger: { log: message => env.logs.push(String(message)) },
    };
  }
}

function assertJsonOutput(output) {
  if (output.mimeType !== 'JSON') throw new Error('The web app answered with ' + output.mimeType + ', not JSON');
}

function triggerBuilder(env, handler) {
  const schedule = {};
  const builder = {
    timeBased: () => builder,
    everyHours: hours => { schedule.everyHours = hours; return builder; },
    everyDays: days => { schedule.everyDays = days; return builder; },
    atHour: hour => { schedule.atHour = hour; return builder; },
    nearMinute: minute => { schedule.nearMinute = minute; return builder; },
    inTimezone: zone => { schedule.timeZone = zone; return builder; },
    create: () => {
      const trigger = { handler, schedule, getHandlerFunction: () => handler };
      env.triggers.push(trigger);
      return trigger;
    },
  };
  return builder;
}

// Java SimpleDateFormat, as far as Code.gs uses it.
function formatDate(date, timeZone, pattern) {
  const at = new Date(date.getTime());
  const parts = {};
  new Intl.DateTimeFormat('en-GB', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
    second: '2-digit', hourCycle: 'h23', weekday: 'short',
  }).formatToParts(at).forEach(part => { parts[part.type] = part.value; });
  const zone = new Intl.DateTimeFormat('en-GB', { timeZone, timeZoneName: 'longOffset' })
    .formatToParts(at).find(part => part.type === 'timeZoneName').value;
  const offset = /GMT([+-]\d\d):(\d\d)/.exec(zone);
  const month = Number(parts.month) - 1;
  const tokens = {
    yyyy: parts.year, MMM: MONTHS[month], MM: parts.month, dd: parts.day,
    d: String(Number(parts.day)), HH: parts.hour, mm: parts.minute, ss: parts.second, EEE: parts.weekday,
    Z: offset ? offset[1] + offset[2] : '+0000',
  };
  return pattern.replace(/'[^']*'|yyyy|MMM|MM|dd|d|HH|mm|ss|EEE|Z/g,
    token => (token.startsWith("'") ? token.slice(1, -1) : tokens[token]));
}

class Builder {
  constructor(initial) { this.spec = initial; }
  whenTextEqualTo(text) { this.spec.textEqualTo = text; return this; }
  whenFormulaSatisfied(formula) { this.spec.formula = formula; return this; }
  setBackground(colour) { this.spec.background = colour; return this; }
  setFontColor(colour) { this.spec.fontColour = colour; return this; }
  setRanges(ranges) { this.spec.ranges = ranges.map(range => range.getA1Notation()); return this; }
  requireValueInList(values, dropdown) { this.spec.values = Array.from(values); this.spec.dropdown = dropdown; return this; }
  setAllowInvalid(allow) { this.spec.allowInvalid = allow; return this; }
  setHelpText(text) { this.spec.helpText = text; return this; }
  build() { return Object.freeze(Object.assign({}, this.spec)); }
}

// ------------------------------------------------------------------------------------------
// Sheets
// ------------------------------------------------------------------------------------------

class FakeSpreadsheet {
  constructor(env, name) {
    this.env = env;
    this.id = env.nextId('sheet');
    this.sheets = [new FakeSheet(this, 'Sheet1')];
    this.timeZone = 'America/Los_Angeles';
    this.locale = 'en_US';
    this.file = env.drive.addFile(this.id, name, SHEETS_MIME);
  }

  getId() { return this.id; }
  getName() { return this.file.name; }
  getUrl() { return 'https://docs.google.com/spreadsheets/d/' + this.id + '/edit'; }
  getSheets() { return this.sheets.slice(); }
  getSheetByName(name) { return this.sheets.find(sheet => sheet.name === name) || null; }
  setSpreadsheetTimeZone(zone) { this.timeZone = zone; }
  setSpreadsheetLocale(locale) { this.locale = locale; }

  insertSheet(name, index) {
    if (this.getSheetByName(name)) throw new Error('A sheet with the name "' + name + '" already exists.');
    const sheet = new FakeSheet(this, name);
    this.sheets.splice(index === undefined ? this.sheets.length : index, 0, sheet);
    return sheet;
  }
}

class FakeSheet {
  constructor(spreadsheet, name) {
    this.spreadsheet = spreadsheet;
    this.name = name;
    this.maxRows = 1000;
    this.maxColumns = 26;
    this.data = [];
    this.formats = [];
    this.formulaCells = [];
    this.writes = [];
    this.frozenRows = 0;
    this.columnWidths = {};
    this.rowHeights = {};
    this.rules = [];
    this.filter = null;
    this.tabColour = null;
    this.hiddenGridlines = false;
  }

  getName() { return this.name; }
  setName(name) { this.name = name; return this; }
  getMaxRows() { return this.maxRows; }
  getMaxColumns() { return this.maxColumns; }
  setFrozenRows(rows) { this.frozenRows = rows; }
  getFrozenRows() { return this.frozenRows; }
  setColumnWidth(column, pixels) { this.columnWidths[column] = pixels; return this; }
  setRowHeight(row, pixels) { this.rowHeights[row] = pixels; return this; }
  setTabColor(colour) { this.tabColour = colour; return this; }
  setHiddenGridlines(hidden) { this.hiddenGridlines = hidden; return this; }
  setConditionalFormatRules(rules) { this.rules = rules.slice(); }
  getConditionalFormatRules() { return this.rules.slice(); }
  getFilter() { return this.filter; }

  getLastRow() {
    for (let r = this.data.length; r >= 1; r--) {
      if ((this.data[r - 1] || []).some(value => value !== '' && value !== undefined)) return r;
    }
    return 0;
  }

  getLastColumn() {
    let last = 0;
    this.data.forEach(row => (row || []).forEach((value, c) => {
      if (value !== '' && value !== undefined) last = Math.max(last, c + 1);
    }));
    return last;
  }

  getRange(row, column, rows = 1, columns = 1) {
    return new FakeRange(this, row, column, rows, columns);
  }

  insertRowsAfter(after, count) {
    if (after < 1 || after > this.maxRows) throw new Error('Those rows are out of bounds.');
    this.data.splice(after, 0, ...Array.from({ length: Math.max(0, Math.min(count, this.data.length - after)) }, () => []));
    this.maxRows += count;
    return this;
  }

  deleteColumns(start, count) {
    if (start + count - 1 > this.maxColumns) throw new Error('Those columns are out of bounds.');
    this.data.forEach(row => row && row.splice(start - 1, count));
    this.maxColumns -= count;
  }

  clear() {
    this.data = [];
    this.formats = [];
    return this;
  }

  value(row, column) {
    const values = this.data[row - 1];
    return values && values[column - 1] !== undefined ? values[column - 1] : '';
  }

  // The last value set for a format property on a cell, as Sheets would show it.
  format(row, column, property) {
    for (let i = this.formats.length - 1; i >= 0; i--) {
      const f = this.formats[i];
      if (f.property === property && row >= f.row && row < f.row + f.rows && column >= f.column && column < f.column + f.columns) {
        return f.value;
      }
    }
    return undefined;
  }
}

class FakeRange {
  constructor(sheet, row, column, rows, columns) {
    if (rows < 1 || columns < 1) throw new Error('The number of rows and columns in the range must be at least 1.');
    if (row < 1 || column < 1 || row + rows - 1 > sheet.maxRows || column + columns - 1 > sheet.maxColumns) {
      throw new Error('The coordinates of the range are outside the dimensions of the sheet.');
    }
    Object.assign(this, { sheet, row, column, rows, columns });
  }

  getLastRow() { return this.row + this.rows - 1; }

  getA1Notation() {
    const letter = n => (n > 26 ? letter(Math.floor((n - 1) / 26)) : '') + String.fromCharCode(65 + ((n - 1) % 26));
    return letter(this.column) + this.row + ':' + letter(this.column + this.columns - 1) + (this.row + this.rows - 1);
  }

  getValues() {
    const out = [];
    for (let r = 0; r < this.rows; r++) {
      const row = [];
      for (let c = 0; c < this.columns; c++) row.push(this.sheet.value(this.row + r, this.column + c));
      out.push(row);
    }
    return out;
  }

  setValues(values) {
    if (values.length !== this.rows || values.some(row => row.length !== this.columns)) {
      throw new Error('The number of rows or columns in the data does not match the range.');
    }
    this.sheet.writes.push({ row: this.row, column: this.column, rows: this.rows, columns: this.columns });
    values.forEach((row, r) => row.forEach((value, c) => this.store(this.row + r, this.column + c, value)));
    return this;
  }

  setValue(value) { return this.setValues([[value]]); }

  clearContent() {
    for (let r = 0; r < this.rows; r++) {
      for (let c = 0; c < this.columns; c++) this.store(this.row + r, this.column + c, '');
    }
    return this;
  }

  store(row, column, value) {
    let stored = value;
    if (value === undefined || (value !== null && typeof value === 'object' && !(typeof value.getTime === 'function'))) {
      throw new Error('Cannot convert ' + JSON.stringify(value) + ' to a cell value.');
    }
    if (typeof value === 'string') {
      if (value.length > 50000) throw new Error('Your input contains more than the maximum of 50000 characters in a single cell.');
      if (value.startsWith("'")) stored = value.slice(1);
      else if (/^[=+\-@]/.test(value)) this.sheet.formulaCells.push({ row, column, value });
    }
    while (this.sheet.data.length < row) this.sheet.data.push([]);
    const cells = this.sheet.data[row - 1] || (this.sheet.data[row - 1] = []);
    cells[column - 1] = stored === null ? '' : stored;
  }

  setFormat(property, value) {
    this.sheet.formats.push({ row: this.row, column: this.column, rows: this.rows, columns: this.columns, property, value });
    return this;
  }

  setNumberFormat(format) { return this.setFormat('numberFormat', format); }
  setFontWeight(weight) { return this.setFormat('fontWeight', weight); }
  setFontColor(colour) { return this.setFormat('fontColour', colour); }
  setFontSize(size) { return this.setFormat('fontSize', size); }
  setFontFamily(family) { return this.setFormat('fontFamily', family); }
  setBackground(colour) { return this.setFormat('background', colour); }
  setHorizontalAlignment(alignment) { return this.setFormat('horizontalAlignment', alignment); }
  setVerticalAlignment(alignment) { return this.setFormat('verticalAlignment', alignment); }
  setWrapStrategy(strategy) { return this.setFormat('wrapStrategy', strategy); }
  setNote(note) { return this.setFormat('note', note); }
  setDataValidation(rule) { return this.setFormat('dataValidation', rule); }

  createFilter() {
    if (this.sheet.filter) throw new Error('You can\'t create a filter in a sheet that already has a filter.');
    this.sheet.filter = new FakeFilter(this.sheet, this);
    return this.sheet.filter;
  }
}

class FakeFilter {
  constructor(sheet, range) {
    this.sheet = sheet;
    this.range = range;
    this.criteria = new Map();
  }

  getRange() { return this.range; }
  getColumnFilterCriteria(column) { return this.criteria.get(column) || null; }
  setColumnFilterCriteria(column, criteria) { this.criteria.set(column, criteria); return this; }
  remove() { this.sheet.filter = null; }
}

// ------------------------------------------------------------------------------------------
// Drive
// ------------------------------------------------------------------------------------------

class FakeDrive {
  constructor(env) {
    this.env = env;
    this.files = new Map();
    this.folders = new Map();
  }

  addFile(id, name, mimeType, parent = 'root') {
    const file = new FakeFile(id, name, mimeType, parent);
    this.files.set(id, file);
    return file;
  }

  addFolder(name, owner = this.env.email) {
    const folder = new FakeFolder(this, this.env.nextId('folder'), name, owner);
    this.folders.set(folder.id, folder);
    return folder;
  }

  api() {
    return {
      Access: { ANYONE: 'ANYONE', ANYONE_WITH_LINK: 'ANYONE_WITH_LINK', DOMAIN: 'DOMAIN', DOMAIN_WITH_LINK: 'DOMAIN_WITH_LINK', PRIVATE: 'PRIVATE' },
      Permission: { VIEW: 'VIEW', EDIT: 'EDIT', COMMENT: 'COMMENT', OWNER: 'OWNER', NONE: 'NONE' },
      getFoldersByName: name => iterate(Array.from(this.folders.values()).filter(folder => folder.name === name)),
      createFolder: name => this.addFolder(name),
      getFolderById: id => {
        if (!this.folders.has(id)) throw new Error('No item with the given ID could be found.');
        return this.folders.get(id);
      },
      getFileById: id => {
        if (!this.files.has(id)) throw new Error('No item with the given ID could be found.');
        return this.files.get(id);
      },
    };
  }
}

function iterate(items) {
  let index = 0;
  return { hasNext: () => index < items.length, next: () => items[index++] };
}

class FakeFolder {
  constructor(drive, id, name, owner) {
    Object.assign(this, { drive, id, name, owner, trashed: false, sharing: null });
  }

  getId() { return this.id; }
  getName() { return this.name; }
  getUrl() { return 'https://drive.google.com/drive/folders/' + this.id; }
  getOwner() { return { getEmail: () => this.owner }; }
  isTrashed() { return this.trashed; }
  setSharing(access, permission) { this.sharing = { access, permission }; return this; }

  getFilesByType(mimeType) {
    return iterate(Array.from(this.drive.files.values())
      .filter(file => file.parent === this.id && file.mimeType === mimeType));
  }
}

class FakeFile {
  constructor(id, name, mimeType, parent) {
    Object.assign(this, { id, name, mimeType, parent, trashed: false, sharing: null });
  }

  getId() { return this.id; }
  getName() { return this.name; }
  isTrashed() { return this.trashed; }
  setTrashed(trashed) { this.trashed = trashed; return this; }
  setSharing(access, permission) { this.sharing = { access, permission }; return this; }
  moveTo(folder) { this.parent = folder.getId(); return this; }
}

// ------------------------------------------------------------------------------------------
// Properties and cache
// ------------------------------------------------------------------------------------------

class FakeProperties {
  constructor() { this.values = new Map(); }

  getProperty(key) { return this.values.has(key) ? this.values.get(key) : null; }
  getKeys() { return Array.from(this.values.keys()); }
  deleteProperty(key) { this.values.delete(key); return this; }

  setProperty(key, value) {
    const text = String(value);
    if (text.length > 9 * 1024) throw new Error('Argument too large: value');
    this.values.set(key, text);
    return this;
  }

  setProperties(values) {
    Object.keys(values).forEach(key => this.setProperty(key, values[key]));
    return this;
  }
}

class FakeCache {
  constructor(env) {
    this.env = env;
    this.entries = new Map();
  }

  check(key, value, seconds) {
    if (key.length > 250) throw new Error('Argument too large: key');
    if (value !== undefined && String(value).length > 100 * 1024) throw new Error('Argument too large: value');
    if (seconds !== undefined && (seconds < 1 || seconds > 21600)) throw new Error('Invalid expiration: ' + seconds);
  }

  get(key) {
    this.check(key);
    const entry = this.entries.get(key);
    return entry && entry.expires > this.env.nowMs ? entry.value : null;
  }

  put(key, value, seconds = 600) {
    this.check(key, value, seconds);
    this.entries.set(key, { value: String(value), expires: this.env.nowMs + seconds * 1000 });
    // Apps Script keeps at most 1,000 entries, dropping those closest to expiring.
    if (this.entries.size > 1000) {
      const kept = Array.from(this.entries.entries()).sort((a, b) => b[1].expires - a[1].expires).slice(0, 900);
      this.entries = new Map(kept);
    }
  }

  getAll(keys) {
    const found = {};
    keys.forEach(key => {
      const value = this.get(key);
      if (value !== null) found[key] = value;
    });
    return found;
  }

  putAll(values, seconds = 600) {
    Object.keys(values).forEach(key => this.put(key, values[key], seconds));
  }

  remove(key) { this.entries.delete(key); }
}

// ------------------------------------------------------------------------------------------
// Uploads
// ------------------------------------------------------------------------------------------

const INSTALL_A = 'E621E1F8-C36C-495A-93FC-0C247A3E6E5F';
const INSTALL_B = '5B1F0D5C-2D7A-4C1E-9E61-7A0C3B8F2D11';

function event(overrides = {}) {
  return Object.assign({
    id: crypto.randomUUID(),
    kind: 'error',
    signature: 'IMAP.throttled@AccountSyncer.swift:131',
    title: 'Gmail paused the connection: too many requests',
    area: 'IMAP',
    count: 1,
    firstAt: '2026-09-24T07:50:00Z',
    lastAt: '2026-09-24T07:55:00Z',
    message: 'NO [THROTTLED] Too many simultaneous connections for <addr:1a2b3c4d>',
    context: { attempt: 3, mailbox: 'Inbox' },
    account: { provider: 'google', kind: 'gmail', host: 'imap.gmail.com', ref: '1a2b3c4d' },
  }, overrides);
}

function upload(env, events, overrides = {}) {
  return Object.assign({
    schema: 1,
    key: env.properties.getProperty('INGEST_KEY'),
    install: INSTALL_A,
    app: { version: '1.10.0', build: '123', channel: 'release' },
    os: 'macOS 26.6 (25G5)',
    hw: 'MacBookPro18,3',
    locale: 'en_US',
    sentAt: new Date(env.nowMs).toISOString(),
    events,
  }, overrides);
}

// A service that has been set up by its owner, as after docs/DIAGNOSTICS_SETUP.md.
function service(options) {
  const env = new Environment(options);
  env.context.setup();
  return env;
}

module.exports = { Environment, service, event, upload, INSTALL_A, INSTALL_B, SHEETS_MIME };
