'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Environment, service } = require('./harness');

const SEPTEMBER = 'FalconMail Diagnostics 2026-09';

test('setup refuses to run as an account outside freightmasters.llc and creates nothing', () => {
  for (const email of ['kamal@gmail.com', 'kamal@freightmasters.llc.example.com', 'kamal@notfreightmasters.llc', '']) {
    const env = new Environment({ email });
    assert.throws(() => env.context.setup(), /signed in to your @freightmasters\.llc Google account/);
    assert.equal(env.drive.folders.size, 0, email);
    assert.equal(env.spreadsheets.size, 0, email);
    assert.deepEqual(env.properties.getKeys(), [], email);
    assert.equal(env.triggers.length, 0, email);
  }
});

test('setup accepts the domain in any letter case', () => {
  const env = service({ email: 'Kamal@FreightMasters.LLC' });
  assert.equal(env.drive.folders.size, 1);
});

test('setup shares the folder and this month\'s spreadsheet with the whole domain', () => {
  const env = service();
  const [folder] = env.drive.folders.values();
  assert.equal(folder.getName(), 'FalconMail Diagnostics');
  assert.deepEqual(folder.sharing, { access: 'DOMAIN', permission: 'VIEW' });

  const spreadsheet = env.spreadsheetNamed(SEPTEMBER);
  assert.ok(spreadsheet, 'the month is named in Baku time');
  assert.equal(spreadsheet.file.parent, folder.getId());
  assert.deepEqual(spreadsheet.file.sharing, { access: 'DOMAIN', permission: 'VIEW' });
  assert.equal(spreadsheet.timeZone, 'Asia/Baku');
});

test('nobody the reports are shared with can share them further', () => {
  const env = service();
  const [folder] = env.drive.folders.values();
  assert.equal(folder.shareableByEditors, false);
  assert.equal(env.spreadsheetNamed(SEPTEMBER).file.shareableByEditors, false);
  env.setNow('2026-09-30T20:15:00Z');
  env.context.dailyMaintenance();
  assert.equal(env.spreadsheetNamed('FalconMail Diagnostics 2026-10').file.shareableByEditors, false, 'next month too');
});

test('each table\'s heading row warns before anyone changes it, once however often setup runs', () => {
  const env = service();
  env.context.setup();
  const spreadsheet = env.spreadsheetNamed(SEPTEMBER);
  for (const name of ['Issues', 'Installs', 'Events']) {
    const sheet = spreadsheet.getSheetByName(name);
    const protections = sheet.getProtections('RANGE');
    assert.equal(protections.length, 1, name);
    assert.equal(protections[0].warningOnly, true, name);
    assert.equal(protections[0].getRange().getA1Notation(), sheet.getRange(1, 1, 1, sheet.getMaxColumns()).getA1Notation(), name);
    assert.match(protections[0].getDescription(), /hide a column instead/, name);
  }
});

test('Events starts with health and launch reports filtered out, and keeps the team\'s own filter', () => {
  const env = service();
  const events = env.spreadsheetNamed(SEPTEMBER).getSheetByName('Events');
  assert.deepEqual(events.getFilter().getColumnFilterCriteria(3).hiddenValues, ['Health', 'Launch']);
  assert.equal(env.spreadsheetNamed(SEPTEMBER).getSheetByName('Issues').getFilter().getColumnFilterCriteria(2), null);
  events.getFilter().remove();
  events.getRange(1, 1, events.getMaxRows(), 17).createFilter();
  env.context.styleTable_(events, env.value('EVENTS_COLUMNS'));
  assert.equal(events.getFilter().getColumnFilterCriteria(3), null, 'a cleared filter stays cleared');
});

test('setup makes two different random keys and logs each once', () => {
  const env = service();
  const ingest = env.properties.getProperty('INGEST_KEY');
  const read = env.properties.getProperty('READ_KEY');
  assert.match(ingest, /^[0-9a-f]{64}$/);
  assert.match(read, /^[0-9a-f]{64}$/);
  assert.notEqual(ingest, read);
  assert.equal(env.logs.filter(line => line.includes(ingest)).length, 1);
  assert.equal(env.logs.filter(line => line.includes(read)).length, 1);
});

test('setup installs an hourly rebuild and a nightly maintenance trigger', () => {
  const env = service();
  const byHandler = Object.fromEntries(env.triggers.map(trigger => [trigger.handler, trigger.schedule]));
  assert.deepEqual(byHandler, {
    rebuildIssues: { everyHours: 1 },
    dailyMaintenance: { everyDays: 1, atHour: 0, nearMinute: 15, timeZone: 'Asia/Baku' },
  });
});

test('running setup again keeps the keys, folder and spreadsheet and does not duplicate triggers', () => {
  const env = service();
  const keys = [env.properties.getProperty('INGEST_KEY'), env.properties.getProperty('READ_KEY')];
  env.logs.length = 0;
  env.context.setup();
  assert.deepEqual([env.properties.getProperty('INGEST_KEY'), env.properties.getProperty('READ_KEY')], keys);
  assert.equal(env.drive.folders.size, 1);
  assert.equal(env.spreadsheets.size, 1);
  assert.equal(env.triggers.length, 2);
  assert.ok(env.logs.some(line => line.includes('already existed')));
  assert.ok(!env.logs.some(line => line.includes(keys[0])), 'keys are not logged again without showKeys()');
});

test('setup never reuses a folder of the same name that someone else owns', () => {
  const env = new Environment();
  const foreign = env.drive.addFolder('FalconMail Diagnostics', 'someone@example.com');
  env.context.setup();
  assert.equal(env.drive.folders.size, 2);
  assert.equal(foreign.sharing, null);
  assert.notEqual(env.properties.getProperty('FOLDER_ID'), foreign.getId());
});

test('the spreadsheet opens on Overview, then Issues, Installs and the raw Events last', () => {
  const env = service();
  const spreadsheet = env.spreadsheetNamed(SEPTEMBER);
  assert.deepEqual(spreadsheet.getSheets().map(sheet => sheet.getName()), ['Overview', 'Issues', 'Installs', 'Events']);
  assert.equal(spreadsheet.getSheetByName('Overview').hiddenGridlines, true);
});

test('every table has a frozen, bold, coloured header, a filter and fixed widths', () => {
  const env = service();
  const spreadsheet = env.spreadsheetNamed(SEPTEMBER);
  for (const name of ['Issues', 'Installs', 'Events']) {
    const sheet = spreadsheet.getSheetByName(name);
    const width = sheet.getMaxColumns();
    assert.equal(sheet.getFrozenRows(), 1, name);
    assert.equal(sheet.format(1, 1, 'fontWeight'), 'bold', name);
    assert.equal(sheet.format(1, width, 'background'), '#27405E', name);
    assert.equal(sheet.getFilter().getRange().getA1Notation(), sheet.getRange(1, 1, sheet.getMaxRows(), width).getA1Notation(), name);
    for (let column = 1; column <= width; column++) assert.ok(sheet.columnWidths[column] > 0, name + ' column ' + column);
    const banding = sheet.getConditionalFormatRules().at(-1);
    assert.equal(banding.formula, '=AND(ISEVEN(ROW()),$A2<>"")', name);
  }
});

test('Issues puts the plain-language title first and widest and the signature last in grey', () => {
  const env = service();
  const sheet = env.spreadsheetNamed(SEPTEMBER).getSheetByName('Issues');
  const headers = sheet.getRange(1, 1, 1, sheet.getMaxColumns()).getValues()[0];
  assert.deepEqual(headers, ['Problem', 'Kind', 'Times', 'Installs affected', 'Testers', 'Versions', 'First seen',
    'Last seen', 'Status', 'Notes', 'Example message', 'Area', 'Signature']);
  const widths = Object.values(sheet.columnWidths);
  assert.equal(sheet.columnWidths[1], Math.max(...widths));
  assert.equal(sheet.format(2, 1, 'wrapStrategy'), 'WRAP');
  assert.equal(sheet.format(2, 13, 'fontColour'), '#80868B');
  assert.equal(sheet.format(2, 3, 'horizontalAlignment'), 'right');
  assert.equal(sheet.format(2, 8, 'numberFormat'), 'd mmm yyyy hh:mm');

  const status = sheet.format(2, 9, 'dataValidation');
  assert.deepEqual(status.values, ['New', 'Investigating', 'Fixed in (type the version)', "Won't fix"]);
  assert.equal(status.allowInvalid, true, 'a version can be typed after "Fixed in"');
  assert.match(sheet.format(1, 9, 'note'), /Kept when this tab is refreshed/);
});

test('Issues colours kinds and greys out closed problems before banding rows', () => {
  const env = service();
  const rules = env.spreadsheetNamed(SEPTEMBER).getSheetByName('Issues').getConditionalFormatRules();
  assert.equal(rules[0].formula,
    '=AND(REGEXMATCH($I2,"(?i)^(fixed in\\s*v?\\d|won.?t fix)"),NOT(REGEXMATCH($F2,"after the fix")))');
  assert.equal(rules[0].fontColour, '#A0A4A8');
  const colours = Object.fromEntries(rules.filter(rule => rule.textEqualTo).map(rule => [rule.textEqualTo, rule.background]));
  assert.equal(colours.Crash, '#F4C7C3');
  assert.equal(colours.Hang, '#FBD9B5');
  assert.equal(colours.CPU, '#FBD9B5');
  assert.equal(colours.Error, '#FCE3A6');
  assert.equal(colours.Warning, '#FFF4C2');
  assert.ok(rules.filter(rule => rule.textEqualTo).every(rule => rule.ranges[0].startsWith('B2:B')));
});

test('Installs and Events keep people-facing columns first and technical detail last', () => {
  const env = service();
  const spreadsheet = env.spreadsheetNamed(SEPTEMBER);
  const headers = name => {
    const sheet = spreadsheet.getSheetByName(name);
    return sheet.getRange(1, 1, 1, sheet.getMaxColumns()).getValues()[0];
  };
  assert.deepEqual(headers('Installs'), ['Diagnostics ID', 'Tester name', 'App version', 'macOS', 'Mac model',
    'First seen', 'Last seen', 'Problems in last 7 days']);
  assert.deepEqual(headers('Events').slice(0, 6), ['Received', 'Problem', 'Kind', 'Diagnostics ID', 'App version', 'Message']);
  assert.equal(headers('Events').at(-1), 'Context');
  const events = spreadsheet.getSheetByName('Events');
  assert.ok(events.columnWidths[17] <= 100, 'Context is narrow');
  assert.equal(events.format(2, 5, 'numberFormat'), '@', 'versions stay text');
});

test('the manifest runs the web app as its owner for anyone, on V8, in Baku time', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'appsscript.json'), 'utf8'));
  assert.equal(manifest.runtimeVersion, 'V8');
  assert.equal(manifest.timeZone, 'Asia/Baku');
  assert.deepEqual(manifest.webapp, { executeAs: 'USER_DEPLOYING', access: 'ANYONE_ANONYMOUS' });
});
