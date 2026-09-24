/**
 * FalconMail diagnostics.
 *
 * Receives redacted problem reports from FalconMail and files them in one Google Sheets
 * spreadsheet a month, inside a Drive folder the whole freightmasters.llc domain can open.
 * Each spreadsheet has four tabs: Overview, Issues, Installs and Events.
 *
 * The contract with the app is docs/DIAGNOSTICS.md. The owner's steps are
 * docs/DIAGNOSTICS_SETUP.md: run setup() once from the editor, then deploy as a web app
 * (Execute as: Me, Who has access: Anyone).
 */

// ============================================================================================
// Settings
// ============================================================================================

const DOMAIN = 'freightmasters.llc';

// What everyone in the domain may do with the folder and its spreadsheets. VIEW lets them read
// the reports. For the team to fill in Status, Notes and Tester name themselves, change this to
// DriveApp.Permission.EDIT (or to DriveApp.Permission.COMMENT for comments only) and run
// setup() again; it re-shares the folder and every spreadsheet in it.
const SHARE_PERMISSION = DriveApp.Permission.VIEW;

const FOLDER_NAME = 'FalconMail Diagnostics';
const SPREADSHEET_PREFIX = 'FalconMail Diagnostics ';
const SPREADSHEET_NAME = /^FalconMail Diagnostics (\d{4}-\d{2})(?: part (\d+))?$/;
const TIME_ZONE = 'Asia/Baku';
const RETENTION_DAYS = 90;

const SCHEMA = 1;
const MAX_BODY_BYTES = 256 * 1024;
const MAX_EVENTS_PER_UPLOAD = 200;
const MAX_UPLOADS_PER_INSTALL_PER_HOUR = 60;
// The ingest key ships inside every public release, so this cap is what protects the daily
// quotas and the spreadsheet if a build misbehaves or someone replays the key: about 250
// events a day for each of ~20 installs.
const MAX_EVENTS_PER_DAY = 5000;
const DEDUPE_HOURS = 6;
const LOCK_WAIT_MS = 20000;

// Sheets refuses a cell over 50,000 characters.
const MAX_CELL_CHARS = 49000;
const MAX_TITLE_CHARS = 120;
const MAX_SIGNATURE_CHARS = 300;
const MAX_MESSAGE_CHARS = 2000;
const MAX_CONTEXT_CHARS = 16 * 1024;
const MAX_SHORT_CHARS = 100;
// A spreadsheet stops growing at 100 MB. A month that would pass this many characters of
// events carries on in a new spreadsheet named "... part 2", well before that point.
const SPREADSHEET_CHAR_BUDGET = 40 * 1000 * 1000;
// Rows added whenever a tab runs out, so formatting is extended every thousand rows at most.
const SPARE_ROWS = 1000;

const READ_LIMIT_DEFAULT = 1000;
const READ_LIMIT_MAX = 5000;
// Keeps a read response to a few megabytes whatever the rows hold.
const READ_CHAR_BUDGET = 4 * 1000 * 1000;

const INSTALL_PATTERN = /^[A-Za-z0-9-]{8,64}$/;
const EVENT_ID_PATTERN = /^[A-Za-z0-9._:-]{1,100}$/;
const KIND_PATTERN = /^[a-z]{1,20}$/;
const NOT_ACCEPTED = 'Not accepted';

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

// Problem kinds in order of severity. Health and launch reports only say an install is alive,
// so they feed the Installs tab and never appear as problems.
const KINDS = {
  crash: { label: 'Crash', severity: 6, problem: true },
  hang: { label: 'Hang', severity: 5, problem: true },
  cpu: { label: 'CPU', severity: 4, problem: true },
  diskwrite: { label: 'Disk writes', severity: 4, problem: true },
  error: { label: 'Error', severity: 3, problem: true },
  warning: { label: 'Warning', severity: 2, problem: true },
  health: { label: 'Health', severity: 1, problem: false },
  launch: { label: 'Launch', severity: 0, problem: false },
};

const COLOURS = {
  header: '#27405E',
  headerText: '#FFFFFF',
  band: '#F4F6F9',
  section: '#E8EEF6',
  tableHeader: '#F1F3F4',
  title: '#1B2B3F',
  text: '#3C4043',
  muted: '#80868B',
  closed: '#A0A4A8',
  alert: '#B3261E',
};

// [labels, background, text colour]: crashes red, hangs and resource problems orange,
// errors amber, warnings yellow, informational reports grey.
const KIND_COLOURS = [
  [['Crash'], '#F4C7C3', '#8C1D18'],
  [['Hang', 'CPU', 'Disk writes'], '#FBD9B5', '#7A3E00'],
  [['Error'], '#FCE3A6', '#6B4A00'],
  [['Warning'], '#FFF4C2', '#5F5200'],
  [['Health', 'Launch'], null, '#80868B'],
];

const DATE_FORMAT = 'd mmm yyyy hh:mm';
const STATUS_NEW = 'New';
const STATUS_CHOICES = ['New', 'Investigating', 'Fixed in …', "Won't fix"];

const OVERVIEW_TAB = 'Overview';
const ISSUES_TAB = 'Issues';
const INSTALLS_TAB = 'Installs';
const EVENTS_TAB = 'Events';

// Column types: wrap (plain text that wraps), text (plain text, clipped), id (monospace),
// technical (small and grey, kept to the right), number (right-aligned), date (Baku time),
// kind (a coloured word) and status (the team's drop-down).
const ISSUES_COLUMNS = [
  { header: 'Problem', key: 'title', width: 340, type: 'wrap' },
  { header: 'Kind', key: 'kind', width: 90, type: 'kind' },
  { header: 'Times', key: 'times', width: 70, type: 'number' },
  { header: 'Installs affected', key: 'installs', width: 80, type: 'number' },
  { header: 'Testers', key: 'testers', width: 160, type: 'wrap' },
  { header: 'Versions', key: 'versions', width: 110, type: 'wrap' },
  { header: 'First seen', key: 'firstSeen', width: 140, type: 'date' },
  { header: 'Last seen', key: 'lastSeen', width: 140, type: 'date' },
  {
    header: 'Status', key: 'status', width: 130, type: 'status',
    note: 'For the team: New, Investigating, Fixed in <version> or Won\'t fix. Kept when this tab is refreshed every hour.',
  },
  { header: 'Notes', key: 'notes', width: 240, type: 'wrap', note: 'For the team. Kept when this tab is refreshed every hour.' },
  { header: 'Example message', key: 'example', width: 320, type: 'wrap' },
  { header: 'Area', key: 'area', width: 100, type: 'technical' },
  { header: 'Signature', key: 'signature', width: 260, type: 'technical' },
];

const INSTALLS_COLUMNS = [
  { header: 'Diagnostics ID', key: 'install', width: 290, type: 'id' },
  {
    header: 'Tester name', key: 'tester', width: 170, type: 'text',
    note: 'Type who uses this Mac. Kept when this tab is refreshed, and shown on Issues and Overview.',
  },
  { header: 'App version', key: 'version', width: 100, type: 'text' },
  { header: 'macOS', key: 'os', width: 190, type: 'text' },
  { header: 'Mac model', key: 'hw', width: 130, type: 'text' },
  { header: 'First seen', key: 'firstSeen', width: 140, type: 'date' },
  { header: 'Last seen', key: 'lastSeen', width: 140, type: 'date' },
  { header: 'Problems in last 7 days', key: 'recent', width: 110, type: 'number' },
];

// The keys are the field names of op=read rows in the contract.
const EVENTS_COLUMNS = [
  { header: 'Received', key: 'receivedAt', width: 140, type: 'date' },
  { header: 'Problem', key: 'title', width: 300, type: 'wrap' },
  { header: 'Kind', key: 'kind', width: 90, type: 'kind' },
  { header: 'Diagnostics ID', key: 'install', width: 150, type: 'id' },
  { header: 'App version', key: 'version', width: 90, type: 'text' },
  { header: 'Message', key: 'message', width: 380, type: 'wrap' },
  { header: 'Times', key: 'count', width: 70, type: 'number' },
  { header: 'First seen', key: 'firstAt', width: 140, type: 'date' },
  { header: 'Last seen', key: 'lastAt', width: 140, type: 'date' },
  { header: 'Area', key: 'area', width: 100, type: 'technical' },
  { header: 'Signature', key: 'signature', width: 260, type: 'technical' },
  { header: 'Build', key: 'build', width: 70, type: 'technical' },
  { header: 'macOS', key: 'os', width: 170, type: 'technical' },
  { header: 'Mac model', key: 'hw', width: 120, type: 'technical' },
  { header: 'Account', key: 'account', width: 200, type: 'technical' },
  { header: 'Event ID', key: 'eventId', width: 150, type: 'technical' },
  { header: 'Context', key: 'context', width: 100, type: 'technical' },
];

const TABLES = [
  { name: ISSUES_TAB, columns: ISSUES_COLUMNS, colour: '#E37400' },
  { name: INSTALLS_TAB, columns: INSTALLS_COLUMNS, colour: '#188038' },
  { name: EVENTS_TAB, columns: EVENTS_COLUMNS, colour: '#80868B' },
];

// ============================================================================================
// Setup (run once by the owner from the Apps Script editor)
// ============================================================================================

function setup() {
  const email = String(Session.getEffectiveUser().getEmail() || '').trim().toLowerCase();
  if (!email.endsWith('@' + DOMAIN)) {
    throw new Error(
      'Run setup() while signed in to your @' + DOMAIN + ' Google account, so the reports stay inside the business. ' +
      (email ? 'This script is running as ' + email + '. ' : 'Google did not say which account is running this script. ') +
      'Nothing was created.');
  }

  const props = PropertiesService.getScriptProperties();
  const folder = ownFolder_(props, email);
  folder.setSharing(DriveApp.Access.DOMAIN, SHARE_PERMISSION);
  const newKeys = ensureKeys_(props);

  const lock = LockService.getScriptLock();
  lock.waitLock(LOCK_WAIT_MS);
  let spreadsheet;
  try {
    spreadsheet = currentSpreadsheet_(new Date(), 0);
  } finally {
    lock.releaseLock();
  }
  listSpreadsheets_(folder).forEach(entry => entry.file.setSharing(DriveApp.Access.DOMAIN, SHARE_PERMISSION));
  installTriggers_();
  rebuildIssues();

  Logger.log('FalconMail diagnostics is set up and shared with everyone at ' + DOMAIN + '.');
  Logger.log('Folder: ' + folder.getUrl());
  Logger.log('This month\'s spreadsheet: ' + spreadsheet.getUrl());
  if (newKeys) {
    logKeys_(props);
  } else {
    Logger.log('The ingest and read keys already existed and were kept. Run showKeys() to see them again.');
  }
  Logger.log('Next: Deploy > New deployment > Web app, Execute as: Me, Who has access: Anyone.');
}

// Shows both keys again in the execution log; only people who can edit this script can run it.
function showKeys() {
  logKeys_(PropertiesService.getScriptProperties());
}

function logKeys_(props) {
  Logger.log('Ingest key (GitHub secret FALCON_DIAGNOSTICS_KEY): ' + props.getProperty('INGEST_KEY'));
  Logger.log('Read key (readKey in ~/.config/falconmail/diagnostics.json): ' + props.getProperty('READ_KEY'));
}

function ensureKeys_(props) {
  if (props.getProperty('INGEST_KEY') && props.getProperty('READ_KEY')) return false;
  props.setProperties({
    INGEST_KEY: props.getProperty('INGEST_KEY') || randomKey_(),
    READ_KEY: props.getProperty('READ_KEY') || randomKey_(),
  });
  return true;
}

function randomKey_() {
  return (Utilities.getUuid() + Utilities.getUuid()).replace(/-/g, '');
}

// Reuses the folder made before, or one of the owner's own with the right name, so running
// setup() again never scatters reports over several folders.
function ownFolder_(props, email) {
  const stored = props.getProperty('FOLDER_ID');
  let folder = stored ? openFolder_(stored) : null;
  const named = folder ? null : DriveApp.getFoldersByName(FOLDER_NAME);
  while (!folder && named.hasNext()) {
    const candidate = named.next();
    if (!candidate.isTrashed() && ownerEmail_(candidate) === email) folder = candidate;
  }
  if (!folder) folder = DriveApp.createFolder(FOLDER_NAME);
  props.setProperty('FOLDER_ID', folder.getId());
  return folder;
}

function ownerEmail_(item) {
  const owner = item.getOwner();
  return owner ? String(owner.getEmail()).toLowerCase() : '';
}

function openFolder_(id) {
  try {
    const folder = DriveApp.getFolderById(id);
    return folder.isTrashed() ? null : folder;
  } catch (error) {
    // Deleted or no longer shared with the owner: the caller finds or makes another.
    return null;
  }
}

function diagnosticsFolder_() {
  const id = PropertiesService.getScriptProperties().getProperty('FOLDER_ID');
  const folder = id ? openFolder_(id) : null;
  if (!folder) throw new Error('The diagnostics folder is missing; run setup() again.');
  return folder;
}

function installTriggers_() {
  const handlers = ['rebuildIssues', 'dailyMaintenance'];
  ScriptApp.getProjectTriggers()
    .filter(trigger => handlers.indexOf(trigger.getHandlerFunction()) >= 0)
    .forEach(trigger => ScriptApp.deleteTrigger(trigger));
  ScriptApp.newTrigger('rebuildIssues').timeBased().everyHours(1).create();
  ScriptApp.newTrigger('dailyMaintenance').timeBased().everyDays(1).atHour(0).nearMinute(15)
    .inTimezone(TIME_ZONE).create();
}

// ============================================================================================
// Web app
// ============================================================================================

function doPost(e) {
  return respond_(() => ingest_(e));
}

function doGet(e) {
  return respond_(() => answer_((e && e.parameter) || {}));
}

function respond_(handler) {
  let result;
  try {
    result = handler();
  } catch (error) {
    console.error(error && error.stack ? error.stack : String(error));
    result = { ok: false, error: 'The diagnostics service failed; try again later' };
  }
  return ContentService.createTextOutput(JSON.stringify(result)).setMimeType(ContentService.MimeType.JSON);
}

function refuse_(message) {
  return { ok: false, error: message };
}

function answer_(params) {
  if (params.op === 'ping') return { ok: true };
  if (params.op !== 'read' && params.op !== 'issues') return refuse_('Unknown operation');
  const readKey = PropertiesService.getScriptProperties().getProperty('READ_KEY');
  if (!sameSecret_(params.key, readKey)) return refuse_(NOT_ACCEPTED);
  return params.op === 'read' ? readEvents_(params) : readIssues_();
}

// Compares every character whatever the input, so response times say nothing about the key.
function sameSecret_(given, expected) {
  if (typeof given !== 'string' || typeof expected !== 'string' || !expected) return false;
  let difference = given.length ^ expected.length;
  for (let i = 0; i < expected.length; i++) {
    difference |= expected.charCodeAt(i) ^ (given.charCodeAt(i) || 0);
  }
  return difference === 0;
}

// ============================================================================================
// Ingest
// ============================================================================================

function ingest_(e) {
  const raw = e && e.postData && typeof e.postData.contents === 'string' ? e.postData.contents : '';
  if (!raw) return refuse_('The upload was empty');
  if (utf8Length_(raw) > MAX_BODY_BYTES) return refuse_('The upload is larger than 256 KB');
  let body;
  try {
    body = JSON.parse(raw);
  } catch (error) {
    return refuse_('The upload is not JSON');
  }
  if (!body || typeof body !== 'object') return refuse_('The upload is not a JSON object');

  const props = PropertiesService.getScriptProperties();
  if (!sameSecret_(body.key, props.getProperty('INGEST_KEY'))) return refuse_(NOT_ACCEPTED);
  if (body.schema !== SCHEMA) return refuse_('Unsupported schema; this service accepts schema ' + SCHEMA);
  if (!Array.isArray(body.events)) return refuse_('The upload has no events list');
  if (body.events.length > MAX_EVENTS_PER_UPLOAD) return refuse_('More than ' + MAX_EVENTS_PER_UPLOAD + ' events in one upload');
  const install = typeof body.install === 'string' && INSTALL_PATTERN.test(body.install) ? body.install : '';
  if (!install) return refuse_('The upload has no valid install ID');
  if (!body.events.length) return { ok: true, accepted: 0, duplicates: 0 };
  if (!allowUpload_(install)) return refuse_('Too many uploads from this install; try again within the hour');

  const upload = uploadFields_(body, install);
  const candidates = [];
  let invalid = 0;
  body.events.forEach(event => {
    const clean = cleanEvent_(event);
    if (clean) candidates.push(clean);
    else invalid += 1;
  });
  if (!candidates.length) return { ok: true, accepted: 0, duplicates: 0, invalid: invalid };

  const lock = LockService.getScriptLock();
  if (!lock.tryLock(LOCK_WAIT_MS)) return refuse_('The service is busy; try again shortly');
  try {
    return store_(props, upload, candidates, invalid);
  } finally {
    lock.releaseLock();
  }
}

// Runs under the script lock, so the dedupe check, the daily count and the row position cannot
// race another upload, and rows are appended in the order they are received.
function store_(props, upload, candidates, invalid) {
  const now = new Date();
  const cache = CacheService.getScriptCache();
  const seen = seenIds_(cache, candidates.map(event => event.id));
  const fresh = candidates.filter(event => {
    if (seen.has(event.id)) return false;
    seen.add(event.id);
    return true;
  });
  const result = { ok: true, accepted: fresh.length, duplicates: candidates.length - fresh.length };
  if (invalid) result.invalid = invalid;
  if (!fresh.length) return result;

  const dayKey = 'EVENTS_ON_' + Utilities.formatDate(now, TIME_ZONE, 'yyyy-MM-dd');
  const today = Number(props.getProperty(dayKey)) || 0;
  if (today + fresh.length > MAX_EVENTS_PER_DAY) return refuse_('The daily limit is reached; try again tomorrow');

  const rows = fresh.map(event => eventRow_(event, upload, now));
  const chars = rows.reduce((sum, row) => sum + rowChars_(row), 0);
  const spreadsheet = currentSpreadsheet_(now, chars);
  appendRows_(spreadsheet.getSheetByName(EVENTS_TAB), EVENTS_COLUMNS, rows);
  SpreadsheetApp.flush();

  seen.save(now);
  props.setProperties({
    [dayKey]: String(today + fresh.length),
    SHEET_CHARS: String((Number(props.getProperty('SHEET_CHARS')) || 0) + chars),
  });
  return result;
}

// A rough per-install limit kept outside the lock, so a runaway install is turned away without
// holding up everyone else; the daily cap is the hard limit.
function allowUpload_(install) {
  const cache = CacheService.getScriptCache();
  const key = 'uploads:' + install + ':' + Math.floor(Date.now() / HOUR_MS);
  const used = Number(cache.get(key)) || 0;
  if (used >= MAX_UPLOADS_PER_INSTALL_PER_HOUR) return false;
  cache.put(key, String(used + 1), 3600);
  return true;
}

// Remembers event IDs for DEDUPE_HOURS in sixteen cache entries rather than one entry per ID:
// the script cache keeps at most 1,000 entries, which a single busy hour would exceed.
function seenIds_(cache, ids) {
  const keyOf = id => 'seen:' + (fnv1a_(id) & 15).toString(16);
  const keys = ids.map(keyOf).filter((key, index, all) => all.indexOf(key) === index);
  const stored = keys.length ? cache.getAll(keys) : {};
  const buckets = {};
  keys.forEach(key => {
    const entries = new Map();
    String(stored[key] || '').split(';').forEach(entry => {
      const parts = entry.split(',');
      if (parts.length === 2) entries.set(parts[0], parseInt(parts[1], 36));
    });
    buckets[key] = entries;
  });
  const touched = {};
  return {
    has: id => buckets[keyOf(id)].has(id),
    add: id => {
      buckets[keyOf(id)].set(id, -1);
      touched[keyOf(id)] = true;
    },
    save: now => {
      const minute = Math.floor(now.getTime() / 60000);
      const values = {};
      Object.keys(touched).forEach(key => {
        const entries = Array.from(buckets[key].entries())
          .map(([id, at]) => [id, at < 0 ? minute : at])
          .filter(([, at]) => minute - at < DEDUPE_HOURS * 60)
          .sort((a, b) => b[1] - a[1]);
        let value = '';
        for (const [id, at] of entries) {
          const entry = id + ',' + at.toString(36) + ';';
          if (value.length + entry.length > 90000) break;
          value += entry;
        }
        values[key] = value;
      });
      if (Object.keys(values).length) cache.putAll(values, DEDUPE_HOURS * 3600);
    },
  };
}

function fnv1a_(text) {
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash;
}

function uploadFields_(body, install) {
  const app = body.app && typeof body.app === 'object' ? body.app : {};
  return {
    install: install,
    version: oneLine_(app.version, 30),
    build: oneLine_(app.build, 30),
    os: oneLine_(body.os, MAX_SHORT_CHARS),
    hw: oneLine_(body.hw, 60),
  };
}

// Returns null for an event that cannot be filed; the rest are stored as sent, trimmed to the
// contract's limits.
function cleanEvent_(event) {
  if (!event || typeof event !== 'object') return null;
  const id = typeof event.id === 'string' && EVENT_ID_PATTERN.test(event.id) ? event.id : '';
  const kind = typeof event.kind === 'string' ? event.kind.trim().toLowerCase() : '';
  const signature = oneLine_(event.signature, MAX_SIGNATURE_CHARS);
  if (!id || !KIND_PATTERN.test(kind) || !signature) return null;
  return {
    id: id,
    kind: kind,
    signature: signature,
    title: oneLine_(event.title, MAX_TITLE_CHARS) || signature,
    area: oneLine_(event.area, 60),
    count: Math.min(Math.max(Math.floor(Number(event.count)) || 1, 1), 1e9),
    firstAt: parseTime_(event.firstAt),
    lastAt: parseTime_(event.lastAt),
    message: truncate_(typeof event.message === 'string' ? event.message.trim() : '', MAX_MESSAGE_CHARS),
    context: contextText_(event.context),
    account: accountText_(event.account),
  };
}

function contextText_(context) {
  if (context === null || context === undefined) return '';
  const text = typeof context === 'string' ? context : JSON.stringify(context);
  return truncate_(text, MAX_CONTEXT_CHARS);
}

// Keeps only the four fields the contract defines, so nothing else about an account is stored.
function accountText_(account) {
  if (!account || typeof account !== 'object') return '';
  const kept = {};
  ['provider', 'kind', 'host', 'ref'].forEach(field => {
    if (typeof account[field] === 'string') kept[field] = oneLine_(account[field], MAX_SHORT_CHARS);
  });
  return JSON.stringify(kept);
}

function eventRow_(event, upload, receivedAt) {
  const lastAt = event.lastAt || event.firstAt || receivedAt;
  const record = {
    receivedAt: receivedAt,
    title: event.title,
    kind: kindLabel_(event.kind),
    install: upload.install,
    version: upload.version,
    message: event.message,
    count: event.count,
    firstAt: event.firstAt || lastAt,
    lastAt: lastAt,
    area: event.area,
    signature: event.signature,
    build: upload.build,
    os: upload.os,
    hw: upload.hw,
    account: event.account,
    eventId: event.id,
    context: event.context,
  };
  return EVENTS_COLUMNS.map(column => cellValue_(record[column.key]));
}

function rowChars_(row) {
  return row.reduce((sum, value) => sum + (typeof value === 'string' ? value.length : 12), 0);
}

// ============================================================================================
// Read (for the owner's tooling)
// ============================================================================================

// Pages through every month's Events oldest first. Rows that arrived together share one
// receivedAt and are never split across pages, so "next" (exclusive) never skips or repeats one.
function readEvents_(params) {
  const since = params.since ? Date.parse(params.since) : -Infinity;
  if (params.since && isNaN(since)) return refuse_('since is not an ISO 8601 date');
  const requested = parseInt(params.limit, 10);
  const limit = Math.min(Math.max(isNaN(requested) ? READ_LIMIT_DEFAULT : requested, 1), READ_LIMIT_MAX);

  const page = { rows: [], chars: 0, lastMs: null, full: false, more: false };
  const spreadsheets = listSpreadsheets_(diagnosticsFolder_());
  for (let i = 0; i < spreadsheets.length && !page.more; i++) {
    const entry = spreadsheets[i];
    if (!page.full && monthStart_(nextMonthKey_(entry.month)) + DAY_MS <= since) continue;
    const spreadsheet = openSpreadsheet_(entry.id);
    const sheet = spreadsheet && spreadsheet.getSheetByName(EVENTS_TAB);
    if (sheet) readSheetPage_(sheet, since, limit, page);
  }
  return {
    ok: true,
    rows: page.rows,
    next: page.more ? new Date(page.lastMs).toISOString() : null,
  };
}

function readSheetPage_(sheet, since, limit, page) {
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) return;
  const times = sheet.getRange(2, 1, lastRow - 1, 1).getValues().map(row => timeOf_(row[0]));
  let index = firstAfter_(times, page.full ? page.lastMs - 1 : since);
  while (index < times.length) {
    const count = Math.min(times.length - index, Math.max(limit - page.rows.length, 0) + MAX_EVENTS_PER_UPLOAD);
    const values = sheet.getRange(index + 2, 1, count, EVENTS_COLUMNS.length).getValues();
    for (let i = 0; i < values.length; i++) {
      const at = times[index + i];
      if (page.full && at !== page.lastMs) {
        page.more = true;
        return;
      }
      const row = readRecord_(values[i], EVENTS_COLUMNS);
      page.rows.push(row);
      page.chars += JSON.stringify(row).length;
      page.lastMs = at;
      if (page.rows.length >= limit || page.chars >= READ_CHAR_BUDGET) page.full = true;
    }
    index += count;
  }
}

// Binary search for the first row received after `after`; rows are appended in time order.
function firstAfter_(times, after) {
  let low = 0;
  let high = times.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (times[middle] > after) high = middle;
    else low = middle + 1;
  }
  return low;
}

function readIssues_() {
  const current = currentSpreadsheetIfAny_();
  const sheet = current && current.getSheetByName(ISSUES_TAB);
  const issues = sheet ? readTable_(sheet, ISSUES_COLUMNS).map(record => {
    const out = {};
    ISSUES_COLUMNS.forEach(column => { out[column.key] = jsonValue_(record[column.key], column); });
    return out;
  }) : [];
  return {
    ok: true,
    updatedAt: PropertiesService.getScriptProperties().getProperty('SUMMARY_UPDATED_AT'),
    issues: issues,
  };
}

function readRecord_(values, columns) {
  const out = {};
  columns.forEach((column, i) => {
    let value = values[i];
    if (column.type === 'kind') value = kindOfLabel_(unescapeText_(value));
    out[column.key] = jsonValue_(value, column);
  });
  return out;
}

function jsonValue_(value, column) {
  if (column.type === 'date') {
    const at = timeOf_(value);
    return isNaN(at) ? null : new Date(at).toISOString();
  }
  if (column.type === 'number') return Number(value) || 0;
  return unescapeText_(value);
}

// ============================================================================================
// Monthly spreadsheets
// ============================================================================================

// The spreadsheet new events go to: this month's in Baku time, or a new one when the month
// has turned or the current one has reached its size budget.
function currentSpreadsheet_(now, incomingChars) {
  const props = PropertiesService.getScriptProperties();
  const month = monthKey_(now);
  const id = props.getProperty('SHEET_ID');
  const sameMonth = props.getProperty('SHEET_MONTH') === month;
  const used = Number(props.getProperty('SHEET_CHARS')) || 0;
  if (id && sameMonth && used + incomingChars <= SPREADSHEET_CHAR_BUDGET) {
    const spreadsheet = openSpreadsheet_(id);
    if (spreadsheet) return spreadsheet;
  }
  const part = sameMonth ? (Number(props.getProperty('SHEET_PART')) || 1) + 1 : 1;
  return createSpreadsheet_(props, month, part, id);
}

function currentSpreadsheetIfAny_() {
  const id = PropertiesService.getScriptProperties().getProperty('SHEET_ID');
  return id ? openSpreadsheet_(id) : null;
}

function openSpreadsheet_(id) {
  try {
    return SpreadsheetApp.openById(id);
  } catch (error) {
    // Deleted by hand: the caller starts a new one.
    return null;
  }
}

function createSpreadsheet_(props, month, part, previousId) {
  const folder = diagnosticsFolder_();
  const spreadsheet = SpreadsheetApp.create(SPREADSHEET_PREFIX + month + (part > 1 ? ' part ' + part : ''));
  spreadsheet.setSpreadsheetTimeZone(TIME_ZONE);
  spreadsheet.setSpreadsheetLocale('en_GB');

  const overview = spreadsheet.getSheets()[0];
  overview.setName(OVERVIEW_TAB);
  overview.setTabColor(COLOURS.header);
  TABLES.forEach((table, index) => {
    const sheet = spreadsheet.insertSheet(table.name, index + 1);
    sheet.setTabColor(table.colour);
    styleTable_(sheet, table.columns);
  });
  writeOverviewPlaceholder_(overview);

  const file = DriveApp.getFileById(spreadsheet.getId());
  file.moveTo(folder);
  // The folder's sharing is inherited; set it on the file too so it holds even if moved.
  file.setSharing(DriveApp.Access.DOMAIN, SHARE_PERMISSION);

  props.setProperties({ SHEET_ID: spreadsheet.getId(), SHEET_MONTH: month, SHEET_PART: String(part), SHEET_CHARS: '0' });
  if (previousId) markClosed_(previousId, spreadsheet);
  return spreadsheet;
}

function markClosed_(previousId, successor) {
  const previous = openSpreadsheet_(previousId);
  const overview = previous && previous.getSheetByName(OVERVIEW_TAB);
  if (!overview) return;
  overview.getRange(2, 1)
    .setValue('Closed. Newer reports are in ' + successor.getName() + ': ' + successor.getUrl())
    .setFontColor(COLOURS.alert)
    .setFontWeight('bold');
}

// This folder's diagnostics spreadsheets, oldest first. Anything else in the folder is ignored.
function listSpreadsheets_(folder) {
  const found = [];
  const files = folder.getFilesByType(MimeType.GOOGLE_SHEETS);
  while (files.hasNext()) {
    const file = files.next();
    const match = SPREADSHEET_NAME.exec(file.getName());
    if (match && !file.isTrashed()) {
      found.push({ file: file, id: file.getId(), month: match[1], part: Number(match[2] || 1) });
    }
  }
  return found.sort((a, b) => (a.month < b.month ? -1 : a.month > b.month ? 1 : a.part - b.part));
}

// Runs every night at about 00:15 Baku time. If uploads keep the lock busy, the month still
// turns over with the first upload of the new month.
function dailyMaintenance() {
  const now = new Date();
  const props = PropertiesService.getScriptProperties();
  const before = props.getProperty('SHEET_ID');
  const lock = LockService.getScriptLock();
  if (lock.tryLock(LOCK_WAIT_MS * 3)) {
    try {
      currentSpreadsheet_(now, 0);
      pruneDailyCounters_(props, now);
    } finally {
      lock.releaseLock();
    }
  }
  applyRetention_(now);
  if (props.getProperty('SHEET_ID') !== before) rebuildIssues();
}

function pruneDailyCounters_(props, now) {
  const today = 'EVENTS_ON_' + Utilities.formatDate(now, TIME_ZONE, 'yyyy-MM-dd');
  props.getKeys()
    .filter(key => key.indexOf('EVENTS_ON_') === 0 && key !== today)
    .forEach(key => props.deleteProperty(key));
}

// Moves a month's spreadsheets to the trash RETENTION_DAYS after that month ends. Only this
// folder's own diagnostics spreadsheets are considered, and never the current one.
function applyRetention_(now) {
  const currentId = PropertiesService.getScriptProperties().getProperty('SHEET_ID');
  listSpreadsheets_(diagnosticsFolder_()).forEach(entry => {
    const ended = monthStart_(nextMonthKey_(entry.month));
    if (entry.id !== currentId && now.getTime() - ended > RETENTION_DAYS * DAY_MS) {
      entry.file.setTrashed(true);
      Logger.log('Moved to the trash after ' + RETENTION_DAYS + ' days: ' + entry.file.getName());
    }
  });
}

// ============================================================================================
// Summaries: Issues, Installs and Overview (rebuilt every hour)
// ============================================================================================

function rebuildIssues() {
  const current = currentSpreadsheetIfAny_();
  if (!current) return;
  const now = new Date();
  const thisMonth = monthKey_(now);
  const window = [previousMonthKey_(thisMonth), thisMonth];
  const spreadsheets = listSpreadsheets_(diagnosticsFolder_());
  const events = readWindowEvents_(spreadsheets.filter(entry => window.indexOf(entry.month) >= 0));

  // The team's Status, Notes and tester names come from this spreadsheet, or from the one
  // before it on the first rebuild after a new month or part begins.
  const position = spreadsheets.map(entry => entry.id).indexOf(current.getId());
  const previous = position > 0 ? openSpreadsheet_(spreadsheets[position - 1].id) : null;

  const installs = buildInstalls_(events, earlierRecords_(current, previous, INSTALLS_TAB, INSTALLS_COLUMNS, 'install'), now);
  const testers = new Map();
  installs.forEach(record => { if (record.tester) testers.set(record.install, record.tester); });
  const issues = buildIssues_(events, earlierRecords_(current, previous, ISSUES_TAB, ISSUES_COLUMNS, 'signature'), testers);

  writeTable_(current.getSheetByName(INSTALLS_TAB), INSTALLS_COLUMNS, installs);
  const issuesSheet = current.getSheetByName(ISSUES_TAB);
  writeTable_(issuesSheet, ISSUES_COLUMNS, issues);
  setStatusChoices_(issuesSheet, issues);
  writeOverview_(current.getSheetByName(OVERVIEW_TAB), {
    now: now,
    since: monthStart_(window[0]),
    events: events,
    issues: issues,
    installs: installs,
  });
  PropertiesService.getScriptProperties().setProperty('SUMMARY_UPDATED_AT', now.toISOString());
}

// Reads the window's events once each: a resent batch that slipped past the cache is counted once.
function readWindowEvents_(entries) {
  const events = [];
  const ids = new Set();
  // Everything but Context, the largest column and not needed for the summaries.
  const columns = EVENTS_COLUMNS.slice(0, -1);
  entries.forEach(entry => {
    const spreadsheet = openSpreadsheet_(entry.id);
    const sheet = spreadsheet && spreadsheet.getSheetByName(EVENTS_TAB);
    const lastRow = sheet ? sheet.getLastRow() : 0;
    if (lastRow < 2) return;
    sheet.getRange(2, 1, lastRow - 1, columns.length).getValues().forEach(values => {
      const event = readRecord_(values, columns);
      if (!event.eventId || ids.has(event.eventId)) return;
      ids.add(event.eventId);
      const received = Date.parse(event.receivedAt);
      const last = Date.parse(event.lastAt);
      const first = Date.parse(event.firstAt);
      // Device clocks can run ahead; nothing is counted as happening after it arrived.
      event.when = isNaN(last) ? received : Math.min(last, received);
      event.firstWhen = isNaN(first) ? event.when : Math.min(first, event.when);
      events.push(event);
    });
  });
  return events;
}

function earlierRecords_(current, previous, tab, columns, keyField) {
  const records = new Map();
  [previous, current].forEach(spreadsheet => {
    const sheet = spreadsheet && spreadsheet.getSheetByName(tab);
    if (!sheet) return;
    readTable_(sheet, columns).forEach(record => {
      if (record[keyField]) records.set(record[keyField], record);
    });
  });
  return records;
}

function buildInstalls_(events, earlier, now) {
  const byInstall = new Map();
  events.forEach(event => {
    let install = byInstall.get(event.install);
    if (!install) {
      install = { install: event.install, firstSeen: event.firstWhen, lastSeen: event.when, latest: -Infinity, recent: 0 };
      byInstall.set(event.install, install);
    }
    install.firstSeen = Math.min(install.firstSeen, event.firstWhen);
    install.lastSeen = Math.max(install.lastSeen, event.when);
    const received = Date.parse(event.receivedAt);
    if (received >= install.latest) {
      install.latest = received;
      install.version = event.version;
      install.os = event.os;
      install.hw = event.hw;
    }
    if (isProblem_(event.kind) && event.when >= now.getTime() - 7 * DAY_MS) install.recent += event.count;
  });

  const records = [];
  byInstall.forEach(install => {
    const before = earlier.get(install.install);
    records.push({
      install: install.install,
      tester: before ? before.tester : '',
      version: install.version,
      os: install.os,
      hw: install.hw,
      firstSeen: new Date(install.firstSeen),
      lastSeen: new Date(install.lastSeen),
      recent: install.recent,
    });
  });
  // A named Mac stays listed after it goes quiet, so the team's name for it is not lost.
  earlier.forEach((before, id) => {
    if (!byInstall.has(id) && before.tester) records.push(Object.assign({}, before, { recent: 0 }));
  });
  return records.sort((a, b) => timeOf_(b.lastSeen) - timeOf_(a.lastSeen));
}

function buildIssues_(events, earlier, testers) {
  const bySignature = new Map();
  events.forEach(event => {
    if (!isProblem_(event.kind)) return;
    let issue = bySignature.get(event.signature);
    if (!issue) {
      issue = {
        signature: event.signature, kind: event.kind, times: 0, installs: new Set(), versions: new Set(),
        firstSeen: event.firstWhen, lastSeen: event.when, latest: -Infinity,
      };
      bySignature.set(event.signature, issue);
    }
    issue.times += event.count;
    issue.installs.add(event.install);
    if (event.version) issue.versions.add(event.version);
    issue.firstSeen = Math.min(issue.firstSeen, event.firstWhen);
    issue.lastSeen = Math.max(issue.lastSeen, event.when);
    if (severity_(event.kind) > severity_(issue.kind)) issue.kind = event.kind;
    if (event.when >= issue.latest) {
      issue.latest = event.when;
      issue.title = event.title;
      issue.area = event.area;
      issue.example = truncate_(event.message, 300);
    }
  });

  const records = [];
  bySignature.forEach(issue => {
    const before = earlier.get(issue.signature);
    records.push({
      title: issue.title,
      kind: issue.kind,
      times: issue.times,
      installs: issue.installs.size,
      testers: testerList_(issue.installs, testers),
      versions: listWithMore_(Array.from(issue.versions).sort(compareVersions_).reverse(), 4),
      firstSeen: new Date(issue.firstSeen),
      lastSeen: new Date(issue.lastSeen),
      status: before ? before.status : STATUS_NEW,
      notes: before ? before.notes : '',
      example: issue.example,
      area: issue.area,
      signature: issue.signature,
      allVersions: Array.from(issue.versions),
    });
  });
  // A problem the team has written about stays listed after it goes quiet, with its last figures.
  earlier.forEach((before, signature) => {
    const annotated = (before.status && before.status !== STATUS_NEW) || before.notes;
    if (!bySignature.has(signature) && annotated) records.push(Object.assign({}, before, { quiet: true }));
  });
  return records.sort((a, b) =>
    statusRank_(a.status) - statusRank_(b.status) ||
    timeOf_(b.lastSeen) - timeOf_(a.lastSeen) ||
    b.times - a.times ||
    severity_(b.kind) - severity_(a.kind));
}

function testerList_(installs, testers) {
  const names = [];
  installs.forEach(install => { if (testers.has(install)) names.push(testers.get(install)); });
  names.sort();
  const unnamed = installs.size - names.length;
  if (!names.length) return '';
  const shown = names.slice(0, 4);
  const others = names.length - shown.length + unnamed;
  return shown.join(', ') + (others ? ' + ' + others + ' more' : '');
}

function listWithMore_(items, max) {
  return items.slice(0, max).join(', ') + (items.length > max ? ' + ' + (items.length - max) + ' more' : '');
}

// Open problems first, then fixed ones, then those the team has decided to leave.
function statusRank_(status) {
  if (/^fixed/i.test(status || '')) return 1;
  if (/^won.?t fix/i.test(status || '')) return 2;
  return 0;
}

function fixedVersion_(status) {
  const match = /^fixed in\s+v?(\d+(?:\.\d+)*)/i.exec(status || '');
  return match ? match[1] : null;
}

// Offers every "Fixed in <version>" the team has already typed as a choice of its own; any other
// text is still allowed, so a new version can be typed after "Fixed in".
function setStatusChoices_(sheet, records) {
  const typed = {};
  records.forEach(record => {
    const version = fixedVersion_(record.status);
    if (version) typed[record.status] = version;
  });
  const fixed = Object.keys(typed).sort((a, b) => compareVersions_(typed[b], typed[a]));
  const choices = STATUS_CHOICES.slice(0, 3).concat(fixed, STATUS_CHOICES.slice(3));
  const column = columnIndex_(ISSUES_COLUMNS, 'status');
  sheet.getRange(2, column, sheet.getMaxRows() - 1, 1).setDataValidation(statusValidation_(choices));
}

function statusValidation_(choices) {
  return SpreadsheetApp.newDataValidation()
    .requireValueInList(choices, true)
    .setAllowInvalid(true)
    .setHelpText('Pick a status. For a fixed problem, type the version after "Fixed in", for example Fixed in 1.10.1.')
    .build();
}

// ============================================================================================
// Overview
// ============================================================================================

const OVERVIEW_WIDTHS = [400, 100, 80, 90, 180, 150];

function writeOverviewPlaceholder_(sheet) {
  writeLines_(sheet, [
    { style: 'title', cells: ['FalconMail diagnostics'] },
    { style: 'muted', cells: ['The first summary appears here within the hour.'] },
  ]);
}

function dayName_(daysAgo, dayStart) {
  if (daysAgo === 0) return 'Today';
  if (daysAgo === 1) return 'Yesterday';
  return formatLocal_(new Date(dayStart), 'EEE d MMM');
}

function writeOverview_(sheet, summary) {
  const now = summary.now;
  const nowMs = now.getTime();
  const lines = [
    { style: 'title', cells: ['FalconMail diagnostics'] },
    {
      style: 'muted',
      cells: ['Last updated ' + formatLocal_(now, 'd MMM yyyy HH:mm') + ', Baku time. Covers reports since ' +
        formatLocal_(new Date(summary.since), 'd MMM yyyy') + '.'],
    },
    {
      style: 'muted',
      cells: ['Issues lists each problem once; the team sets its Status and Notes there. ' +
        'Installs shows who uses which Mac. Events holds every report as it arrived.'],
    },
    { style: 'blank', cells: [] },
  ];

  const day = activity_(summary.events, nowMs - DAY_MS, Infinity);
  lines.push(
    { style: 'section', cells: ['Last 24 hours'] },
    { style: 'row', cells: ['Problems reported', day.times] },
    { style: 'row', cells: ['Different problems', day.signatures.size] },
    { style: 'row', cells: ['Crashes', day.crashes] },
    { style: 'row', cells: ['Installs active', day.installs.size] },
    { style: 'blank', cells: [] });

  lines.push(
    { style: 'section', cells: ['Last 7 days'] },
    { style: 'header', cells: ['Day', 'Problems', 'Crashes', 'Installs active'], align: [, 'right', 'right', 'right'] });
  let dayEnd = Infinity;
  for (let i = 0; i < 7; i++) {
    const dayStart = startOfLocalDay_(new Date(nowMs - i * DAY_MS));
    const stats = activity_(summary.events, dayStart, dayEnd);
    lines.push({
      style: 'row',
      cells: [dayName_(i, dayStart), stats.times, stats.crashes, stats.installs.size],
    });
    dayEnd = dayStart;
  }
  lines.push({ style: 'blank', cells: [] });

  const active = summary.issues.filter(record => !record.quiet);
  const open = active.filter(record => statusRank_(record.status) === 0)
    .sort((a, b) => b.times - a.times || severity_(b.kind) - severity_(a.kind) || timeOf_(b.lastSeen) - timeOf_(a.lastSeen))
    .slice(0, 10);
  lines.push(
    { style: 'section', cells: ['Most frequent open problems'] },
    {
      style: 'header',
      cells: ['Problem', 'Kind', 'Times', 'Installs', 'Testers', 'Last seen'],
      align: [, 'center', 'right', 'right', , 'right'],
    });
  open.forEach(record => lines.push({
    style: 'row',
    kindColumn: 2,
    cells: [record.title, kindLabel_(record.kind), record.times, record.installs, record.testers, record.lastSeen],
  }));
  if (!open.length) lines.push({ style: 'muted', cells: ['No open problems.'] });
  lines.push({ style: 'blank', cells: [] });

  const returned = active.map(record => {
    const fixedIn = fixedVersion_(record.status);
    const since = fixedIn ? record.allVersions.filter(version => compareVersions_(version, fixedIn) >= 0) : [];
    return { record: record, since: since.sort(compareVersions_).reverse() };
  }).filter(item => item.since.length);
  if (returned.length) {
    lines.push(
      { style: 'section', cells: ['Back after a fix'] },
      { style: 'header', cells: ['Problem', 'Status', '', '', 'Seen again in', 'Last seen'], align: [, , , , , 'right'] });
    returned.forEach(item => lines.push({
      style: 'row',
      cells: [item.record.title, item.record.status, '', '', item.since.join(', '), item.record.lastSeen],
    }));
    lines.push({ style: 'blank', cells: [] });
  }

  const versions = new Map();
  summary.installs.forEach(record => {
    if (timeOf_(record.lastSeen) >= nowMs - 7 * DAY_MS && record.version) {
      versions.set(record.version, (versions.get(record.version) || 0) + 1);
    }
  });
  lines.push(
    { style: 'section', cells: ['Versions in use (last 7 days)'] },
    { style: 'header', cells: ['Version', 'Installs'], align: [, 'right'] });
  Array.from(versions.keys()).sort(compareVersions_).reverse()
    .forEach(version => lines.push({ style: 'row', cells: [version, versions.get(version)] }));
  if (!versions.size) lines.push({ style: 'muted', cells: ['No installs reported in the last 7 days.'] });

  writeLines_(sheet, lines);
}

// Problems, crashes and active installs among events that happened in [from, to).
function activity_(events, from, to) {
  const stats = { times: 0, crashes: 0, signatures: new Set(), installs: new Set() };
  events.forEach(event => {
    if (event.when < from || event.when >= to) return;
    stats.installs.add(event.install);
    if (!isProblem_(event.kind)) return;
    stats.times += event.count;
    stats.signatures.add(event.signature);
    if (event.kind === 'crash') stats.crashes += event.count;
  });
  return stats;
}

function writeLines_(sheet, lines) {
  const width = OVERVIEW_WIDTHS.length;
  sheet.clear();
  sheet.setConditionalFormatRules([]);
  sheet.setHiddenGridlines(true);
  if (sheet.getMaxRows() < lines.length) sheet.insertRowsAfter(sheet.getMaxRows(), lines.length - sheet.getMaxRows());
  if (sheet.getMaxColumns() > width) sheet.deleteColumns(width + 1, sheet.getMaxColumns() - width);
  OVERVIEW_WIDTHS.forEach((pixels, i) => sheet.setColumnWidth(i + 1, pixels));

  const values = lines.map(line => {
    const cells = line.cells.map(cellValue_);
    while (cells.length < width) cells.push('');
    return cells;
  });
  sheet.getRange(1, 1, values.length, width).setValues(values);

  lines.forEach((line, index) => {
    const row = index + 1;
    const range = sheet.getRange(row, 1, 1, width);
    range.setVerticalAlignment('middle').setFontColor(COLOURS.text);
    if (line.style === 'title') {
      range.setFontSize(18).setFontWeight('bold').setFontColor(COLOURS.title);
      sheet.setRowHeight(row, 40);
    } else if (line.style === 'muted') {
      range.setFontColor(COLOURS.muted);
    } else if (line.style === 'section') {
      range.setFontSize(12).setFontWeight('bold').setBackground(COLOURS.section).setFontColor(COLOURS.title);
      sheet.setRowHeight(row, 28);
    } else if (line.style === 'header') {
      range.setFontWeight('bold').setBackground(COLOURS.tableHeader);
      (line.align || []).forEach((alignment, i) => sheet.getRange(row, i + 1).setHorizontalAlignment(alignment));
    } else if (line.style === 'row') {
      sheet.getRange(row, 1).setWrapStrategy(SpreadsheetApp.WrapStrategy.WRAP);
      line.cells.forEach((cell, i) => {
        const target = sheet.getRange(row, i + 1);
        if (typeof cell === 'number') target.setNumberFormat('#,##0').setHorizontalAlignment('right');
        else if (isDate_(cell)) target.setNumberFormat(DATE_FORMAT).setHorizontalAlignment('right');
      });
      if (line.kindColumn) paintKind_(sheet.getRange(row, line.kindColumn), line.cells[line.kindColumn - 1]);
    }
  });
}

function paintKind_(range, label) {
  KIND_COLOURS.forEach(([labels, background, text]) => {
    if (labels.indexOf(label) < 0) return;
    if (background) range.setBackground(background);
    range.setFontColor(text).setHorizontalAlignment('center');
  });
}

// ============================================================================================
// Tables: layout and styling
// ============================================================================================

// Everything here covers every row of the tab, so it only needs doing when the tab is made
// and whenever it grows.
function styleTable_(sheet, columns) {
  const width = columns.length;
  const rows = sheet.getMaxRows();
  if (sheet.getMaxColumns() > width) sheet.deleteColumns(width + 1, sheet.getMaxColumns() - width);

  sheet.getRange(1, 1, 1, width)
    .setValues([columns.map(column => column.header)])
    .setFontWeight('bold')
    .setBackground(COLOURS.header)
    .setFontColor(COLOURS.headerText)
    .setVerticalAlignment('middle')
    .setWrapStrategy(SpreadsheetApp.WrapStrategy.WRAP);
  sheet.setFrozenRows(1);
  sheet.setRowHeight(1, 36);

  columns.forEach((column, i) => {
    sheet.setColumnWidth(i + 1, column.width);
    if (column.note) sheet.getRange(1, i + 1).setNote(column.note);
    const body = sheet.getRange(2, i + 1, rows - 1, 1).setVerticalAlignment('top');
    if (column.type === 'date') {
      body.setNumberFormat(DATE_FORMAT).setHorizontalAlignment('right');
    } else if (column.type === 'number') {
      body.setNumberFormat('#,##0').setHorizontalAlignment('right');
    } else {
      // Plain text, so Sheets never turns "1.10" into a number or "2026-09" into a date.
      body.setNumberFormat('@');
      body.setWrapStrategy(column.type === 'wrap' ? SpreadsheetApp.WrapStrategy.WRAP : SpreadsheetApp.WrapStrategy.CLIP);
    }
    if (column.type === 'technical') body.setFontColor(COLOURS.muted).setFontSize(9);
    if (column.type === 'id') body.setFontFamily('Roboto Mono').setFontSize(9);
    if (column.type === 'kind') body.setHorizontalAlignment('center');
    if (column.type === 'status') body.setDataValidation(statusValidation_(STATUS_CHOICES));
  });

  sheet.setConditionalFormatRules(tableRules_(sheet, columns, rows));
  refreshFilter_(sheet, width);
}

// Sheets applies only the first matching rule to a cell, so the order matters: closed problems
// are greyed out whole, then kinds get their colours, then rows are banded.
function tableRules_(sheet, columns, rows) {
  const width = columns.length;
  const all = sheet.getRange(2, 1, rows - 1, width);
  const rules = [];
  const status = columnIndex_(columns, 'status');
  if (status) {
    const cell = '$' + columnLetter_(status) + '2';
    rules.push(SpreadsheetApp.newConditionalFormatRule()
      .whenFormulaSatisfied('=REGEXMATCH(' + cell + ',"(?i)^(fixed|won.?t fix)")')
      .setFontColor(COLOURS.closed)
      .setRanges([all])
      .build());
  }
  const kind = columnIndex_(columns, 'kind');
  if (kind) {
    const kindRange = sheet.getRange(2, kind, rows - 1, 1);
    KIND_COLOURS.forEach(([labels, background, text]) => labels.forEach(label => {
      const rule = SpreadsheetApp.newConditionalFormatRule().whenTextEqualTo(label).setFontColor(text).setRanges([kindRange]);
      if (background) rule.setBackground(background);
      rules.push(rule.build());
    }));
  }
  rules.push(SpreadsheetApp.newConditionalFormatRule()
    .whenFormulaSatisfied('=AND(ISEVEN(ROW()),$A2<>"")')
    .setBackground(COLOURS.band)
    .setRanges([all])
    .build());
  return rules;
}

// Recreates the filter over the whole tab, keeping whatever the team had filtered on.
function refreshFilter_(sheet, width) {
  const existing = sheet.getFilter();
  const criteria = [];
  if (existing) {
    for (let column = 1; column <= width; column++) {
      const kept = existing.getColumnFilterCriteria(column);
      if (kept) criteria.push([column, kept]);
    }
    existing.remove();
  }
  const filter = sheet.getRange(1, 1, sheet.getMaxRows(), width).createFilter();
  criteria.forEach(([column, kept]) => filter.setColumnFilterCriteria(column, kept));
}

function ensureRows_(sheet, columns, lastRow) {
  const maxRows = sheet.getMaxRows();
  if (lastRow <= maxRows) return;
  sheet.insertRowsAfter(maxRows, lastRow - maxRows + SPARE_ROWS);
  styleTable_(sheet, columns);
}

function appendRows_(sheet, columns, rows) {
  const first = sheet.getLastRow() + 1;
  ensureRows_(sheet, columns, first + rows.length - 1);
  sheet.getRange(first, 1, rows.length, columns.length).setValues(rows);
}

function writeTable_(sheet, columns, records) {
  const width = columns.length;
  ensureRows_(sheet, columns, records.length + 1);
  const lastRow = sheet.getLastRow();
  if (lastRow > 1) sheet.getRange(2, 1, lastRow - 1, width).clearContent();
  if (!records.length) return;
  const values = records.map(record => columns.map(column => {
    const value = column.type === 'kind' ? kindLabel_(record[column.key]) : record[column.key];
    return cellValue_(value);
  }));
  sheet.getRange(2, 1, values.length, width).setValues(values);
}

// Reads a tab by its header names, so a column the team has moved is still found.
function readTable_(sheet, columns) {
  const lastRow = sheet.getLastRow();
  const lastColumn = sheet.getLastColumn();
  if (lastRow < 2 || !lastColumn) return [];
  const values = sheet.getRange(1, 1, lastRow, lastColumn).getValues();
  const headers = values[0].map(header => String(header).trim());
  const positions = columns.map(column => headers.indexOf(column.header));
  return values.slice(1).map(row => {
    const record = {};
    columns.forEach((column, i) => {
      const value = positions[i] >= 0 ? row[positions[i]] : '';
      if (column.type === 'kind') record[column.key] = kindOfLabel_(unescapeText_(value));
      else if (column.type === 'number') record[column.key] = Number(value) || 0;
      else if (column.type === 'date') record[column.key] = isDate_(value) ? value : '';
      else record[column.key] = unescapeText_(value);
    });
    return record;
  });
}

function columnIndex_(columns, key) {
  for (let i = 0; i < columns.length; i++) if (columns[i].key === key) return i + 1;
  return 0;
}

function columnLetter_(index) {
  let letters = '';
  for (let n = index; n > 0; n = Math.floor((n - 1) / 26)) letters = String.fromCharCode(65 + ((n - 1) % 26)) + letters;
  return letters;
}

// ============================================================================================
// Small helpers
// ============================================================================================

function kindLabel_(kind) {
  return KINDS[kind] ? KINDS[kind].label : String(kind || '');
}

function kindOfLabel_(label) {
  for (const kind in KINDS) if (KINDS[kind].label === label) return kind;
  return String(label || '').toLowerCase();
}

function isProblem_(kind) {
  return KINDS[kind] ? KINDS[kind].problem : true;
}

function severity_(kind) {
  return KINDS[kind] ? KINDS[kind].severity : 3;
}

// Text written to a cell: kept under the cell limit, and never read by Sheets as a formula.
function cellValue_(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'number' || isDate_(value)) return value;
  const text = truncate_(String(value), MAX_CELL_CHARS);
  return /^[=+\-@\t\r]/.test(text) ? "'" + text : text;
}

// Sheets drops the leading apostrophe that cellValue_ adds; this also covers a cell where it
// was kept.
function unescapeText_(value) {
  if (value === null || value === undefined) return '';
  if (isDate_(value)) return value.toISOString();
  const text = String(value);
  return /^'[=+\-@\t\r]/.test(text) ? text.slice(1) : text;
}

function truncate_(text, max) {
  return text.length > max ? text.slice(0, max - 1) + '…' : text;
}

function oneLine_(value, max) {
  return typeof value === 'string' ? truncate_(value.replace(/\s+/g, ' ').trim(), max) : '';
}

function parseTime_(value) {
  if (typeof value !== 'string') return null;
  const at = Date.parse(value);
  return isNaN(at) ? null : new Date(at);
}

function isDate_(value) {
  return Object.prototype.toString.call(value) === '[object Date]';
}

function timeOf_(value) {
  if (isDate_(value)) return value.getTime();
  if (typeof value === 'number') return value;
  return value ? Date.parse(value) : NaN;
}

function utf8Length_(text) {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xd800 && code < 0xdc00) bytes += 4;
    else if (code >= 0xdc00 && code < 0xe000) bytes += 0;
    else bytes += 3;
  }
  return bytes;
}

function compareVersions_(a, b) {
  const left = String(a).split(/[^0-9]+/).filter(Boolean).map(Number);
  const right = String(b).split(/[^0-9]+/).filter(Boolean).map(Number);
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const difference = (left[i] || 0) - (right[i] || 0);
    if (difference) return difference;
  }
  return 0;
}

function formatLocal_(date, pattern) {
  return Utilities.formatDate(date, TIME_ZONE, pattern);
}

function monthKey_(date) {
  return formatLocal_(date, 'yyyy-MM');
}

function previousMonthKey_(month) {
  const [year, number] = month.split('-').map(Number);
  return number === 1 ? (year - 1) + '-12' : year + '-' + String(number - 1).padStart(2, '0');
}

function nextMonthKey_(month) {
  const [year, number] = month.split('-').map(Number);
  return number === 12 ? (year + 1) + '-01' : year + '-' + String(number + 1).padStart(2, '0');
}

// Midnight in Baku at the start of the month, in milliseconds.
function monthStart_(month) {
  const [year, number] = month.split('-').map(Number);
  return localMidnight_(year, number, 1);
}

function startOfLocalDay_(date) {
  const [year, month, day] = formatLocal_(date, 'yyyy-MM-dd').split('-').map(Number);
  return localMidnight_(year, month, day);
}

function localMidnight_(year, month, day) {
  const utc = Date.UTC(year, month - 1, day);
  const offset = /^([+-])(\d\d)(\d\d)$/.exec(formatLocal_(new Date(utc), 'Z'));
  const minutes = offset ? (offset[1] === '-' ? -1 : 1) * (Number(offset[2]) * 60 + Number(offset[3])) : 0;
  return utc - minutes * 60000;
}
