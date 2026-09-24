'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { service, event, upload, SHEETS_MIME } = require('./harness');

const DOCS_MIME = 'application/vnd.google-apps.document';

test('retention trashes only this folder\'s diagnostics spreadsheets 90 days after their month ends', () => {
  const env = service();
  const folderId = env.properties.getProperty('FOLDER_ID');
  const elsewhere = env.drive.addFolder('Other');
  const files = {
    may: env.drive.addFile('may', 'FalconMail Diagnostics 2026-05', SHEETS_MIME, folderId),
    mayPart2: env.drive.addFile('may-2', 'FalconMail Diagnostics 2026-05 part 2', SHEETS_MIME, folderId),
    june: env.drive.addFile('june', 'FalconMail Diagnostics 2026-06', SHEETS_MIME, folderId),
    budget: env.drive.addFile('budget', 'Budget 2026-01', SHEETS_MIME, folderId),
    notes: env.drive.addFile('notes', 'FalconMail Diagnostics 2026-01', DOCS_MIME, folderId),
    otherFolder: env.drive.addFile('other', 'FalconMail Diagnostics 2026-01', SHEETS_MIME, elsewhere.getId()),
  };
  env.context.dailyMaintenance();

  // May ended on 1 June, 115 days before 24 September; June ended 85 days before.
  assert.equal(files.may.isTrashed(), true);
  assert.equal(files.mayPart2.isTrashed(), true);
  assert.equal(files.june.isTrashed(), false);
  assert.equal(files.budget.isTrashed(), false);
  assert.equal(files.notes.isTrashed(), false);
  assert.equal(files.otherFolder.isTrashed(), false);
  assert.equal(env.spreadsheetNamed('FalconMail Diagnostics 2026-09').file.isTrashed(), false);
  assert.ok(env.logs.some(line => line === 'Moved to the trash after 90 days: FalconMail Diagnostics 2026-05'));
});

test('the current spreadsheet is never trashed, however old its month', () => {
  const env = service();
  env.setNow('2027-03-01T08:00:00Z');
  env.lockAvailable = false; // uploads kept the lock busy, so the month has not turned yet
  env.context.dailyMaintenance();
  assert.equal(env.spreadsheetNamed('FalconMail Diagnostics 2026-09').file.isTrashed(), false);
});

test('the nightly run starts the new month and summarises it straight away', () => {
  const env = service();
  env.post(upload(env, [event()]));
  env.setNow('2026-09-30T20:15:00Z');
  env.context.dailyMaintenance();
  const october = env.spreadsheetNamed('FalconMail Diagnostics 2026-10');
  assert.ok(october);
  assert.equal(october.getSheetByName('Overview').value(1, 1), 'FalconMail diagnostics');
  assert.match(october.getSheetByName('Overview').value(2, 1), /^Last updated 1 Oct 2026 00:15/);
  assert.equal(october.getSheetByName('Issues').value(2, 1), 'Gmail paused the connection: too many requests');
});

test('the nightly run forgets earlier days\' upload counts', () => {
  const env = service();
  env.properties.setProperty('EVENTS_ON_2026-09-22', '120');
  env.properties.setProperty('EVENTS_ON_2026-09-23', '80');
  env.properties.setProperty('CHARS_ON_2026-09-23', '8000');
  env.properties.setProperty('INSTALLS_ON_2026-09-23', '{}');
  env.post(upload(env, [event()]));
  env.context.dailyMaintenance();
  assert.deepEqual(env.properties.getKeys().filter(key => /_ON_/.test(key)).sort(),
    ['CHARS_ON_2026-09-24', 'EVENTS_ON_2026-09-24', 'INSTALLS_ON_2026-09-24']);
});

// A spreadsheet named like a diagnostics one, put in the folder by someone else, with one event.
function planted(env, name, owner) {
  const spreadsheet = env.context.SpreadsheetApp.create(name);
  const sheet = spreadsheet.insertSheet('Events');
  const header = env.value('EVENTS_COLUMNS').map(column => column.header);
  sheet.getRange(1, 1, 1, header.length).setValues([header]);
  const row = header.map(() => '');
  row[0] = new Date(env.nowMs);
  row[1] = 'Planted problem';
  row[2] = 'Crash';
  row[3] = 'ABCDEF01-2345-6789-ABCD-EF0123456789';
  row[6] = 1;
  row[10] = 'Planted.signature';
  row[15] = 'planted-event';
  sheet.getRange(2, 1, 1, header.length).setValues([row]);
  spreadsheet.file.parent = env.properties.getProperty('FOLDER_ID');
  spreadsheet.file.owner = owner;
  return spreadsheet;
}

test('a spreadsheet someone else put in the folder is never trashed, read or counted', () => {
  const env = service();
  env.post(upload(env, [event()]));
  const old = planted(env, 'FalconMail Diagnostics 2020-01', 'teammate@freightmasters.llc');
  planted(env, 'FalconMail Diagnostics 2026-09 part 9', 'teammate@freightmasters.llc');
  const may = env.drive.addFile('may', 'FalconMail Diagnostics 2026-05', SHEETS_MIME, env.properties.getProperty('FOLDER_ID'));

  env.context.dailyMaintenance();
  assert.equal(old.file.isTrashed(), false);
  assert.equal(may.isTrashed(), true, 'retention carries on past it');
  const readKey = env.properties.getProperty('READ_KEY');
  assert.deepEqual(env.get({ op: 'read', key: readKey }).rows.map(row => row.title), ['Gmail paused the connection: too many requests']);
  env.context.rebuildIssues();
  assert.deepEqual(env.table('FalconMail Diagnostics 2026-09', 'Issues').map(row => row.Problem),
    ['Gmail paused the connection: too many requests']);
});

test('a spreadsheet that cannot be trashed is logged and the rest still go', () => {
  const env = service();
  const folderId = env.properties.getProperty('FOLDER_ID');
  const april = env.drive.addFile('april', 'FalconMail Diagnostics 2026-04', SHEETS_MIME, folderId);
  const may = env.drive.addFile('may', 'FalconMail Diagnostics 2026-05', SHEETS_MIME, folderId);
  april.setTrashed = () => { throw new Error('Service error: Drive'); };
  env.context.dailyMaintenance();
  assert.equal(may.isTrashed(), true);
  assert.ok(env.errors.some(line => line.startsWith('Could not move FalconMail Diagnostics 2026-04 to the trash')));
});
