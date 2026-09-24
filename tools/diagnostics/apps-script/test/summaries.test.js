'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { service, event, upload, INSTALL_A, INSTALL_B } = require('./harness');

const SEPTEMBER = 'FalconMail Diagnostics 2026-09';
const THROTTLED = 'IMAP.throttled@AccountSyncer.swift:131';
const CRASH = 'Crash.EXC_BAD_ACCESS@MessageView.swift:88';

const crash = overrides => event(Object.assign({
  kind: 'crash', signature: CRASH, title: 'FalconMail crashed while opening a message', area: 'Reader', message: 'EXC_BAD_ACCESS',
}, overrides));

// Types into a cell the way a teammate would, finding the row by one of its columns.
function typeInto(env, spreadsheetName, tab, match, header, value) {
  const sheet = env.spreadsheetNamed(spreadsheetName).getSheetByName(tab);
  const rows = env.table(spreadsheetName, tab);
  const index = rows.findIndex(row => Object.entries(match).every(([key, wanted]) => row[key] === wanted));
  assert.ok(index >= 0, 'no row matches ' + JSON.stringify(match));
  const headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  sheet.getRange(index + 2, headers.indexOf(header) + 1).setValue(value);
}

function overviewLines(env, name = SEPTEMBER) {
  const sheet = env.spreadsheetNamed(name).getSheetByName('Overview');
  return sheet.getRange(1, 1, sheet.getLastRow(), 6).getValues();
}

test('Issues has one row per problem, and health and launch reports are not problems', () => {
  const env = service();
  env.post(upload(env, [event({ count: 4 }), crash(), event({ kind: 'launch', signature: 'App.launch' }), event({ kind: 'health', signature: 'App.health' })]));
  env.advance(60 * 1000);
  env.post(upload(env, [event({ count: 2, lastAt: '2026-09-24T07:58:00Z' })], { install: INSTALL_B, app: { version: '1.10.1', build: '130' } }));
  env.context.rebuildIssues();

  const issues = env.table(SEPTEMBER, 'Issues');
  assert.deepEqual(issues.map(row => row.Signature), [THROTTLED, CRASH]);
  const [throttled, crashed] = issues;
  assert.equal(throttled.Problem, 'Gmail paused the connection: too many requests');
  assert.equal(throttled.Kind, 'Error');
  assert.equal(throttled.Times, 6);
  assert.equal(throttled['Installs affected'], 2);
  assert.equal(throttled.Versions, '1.10.1, 1.10.0');
  assert.equal(throttled['First seen'].toISOString(), '2026-09-24T07:50:00.000Z');
  assert.equal(throttled['Last seen'].toISOString(), '2026-09-24T07:58:00.000Z');
  assert.equal(throttled.Status, 'New');
  assert.equal(crashed.Kind, 'Crash');

  const installs = env.table(SEPTEMBER, 'Installs');
  assert.deepEqual(installs.map(row => [row['Diagnostics ID'], row['App version'], row['Problems in last 7 days']]), [
    [INSTALL_B, '1.10.1', 2],
    [INSTALL_A, '1.10.0', 5],
  ]);
});

test('Status and Notes typed by the team survive a rebuild even when their row moves', () => {
  const env = service();
  env.post(upload(env, [event(), crash({ lastAt: '2026-09-24T07:00:00Z' })]));
  env.context.rebuildIssues();
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Status', 'Investigating');
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Notes', 'Only with very long threads');
  assert.equal(env.table(SEPTEMBER, 'Issues')[1].Signature, CRASH);

  env.advance(60 * 60 * 1000);
  env.post(upload(env, [crash({ lastAt: '2026-09-24T08:30:00Z' })]));
  env.context.rebuildIssues();
  const [top] = env.table(SEPTEMBER, 'Issues');
  assert.equal(top.Signature, CRASH, 'the crash is now the most recent problem');
  assert.equal(top.Status, 'Investigating');
  assert.equal(top.Notes, 'Only with very long threads');
  assert.equal(top.Times, 2);
});

test('fixed and won\'t-fix problems sink below open ones', () => {
  const env = service();
  env.post(upload(env, [
    event({ lastAt: '2026-09-24T07:59:00Z' }),
    crash({ lastAt: '2026-09-24T07:58:00Z' }),
    event({ signature: 'SMTP.auth@Sender.swift:40', title: 'Sending failed: the server refused the password', lastAt: '2026-09-24T07:57:00Z' }),
  ]));
  env.context.rebuildIssues();
  typeInto(env, SEPTEMBER, 'Issues', { Signature: THROTTLED }, 'Status', 'Fixed in 1.10.1');
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Status', "Won't fix");
  env.context.rebuildIssues();
  assert.deepEqual(env.table(SEPTEMBER, 'Issues').map(row => row.Status), ['New', 'Fixed in 1.10.1', "Won't fix"]);
});

test('a typed "Fixed in" version becomes a drop-down choice of its own', () => {
  const env = service();
  env.post(upload(env, [event(), crash()]));
  env.context.rebuildIssues();
  typeInto(env, SEPTEMBER, 'Issues', { Signature: THROTTLED }, 'Status', 'Fixed in 1.10.1');
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Status', 'Fixed in 1.9.4');
  env.context.rebuildIssues();
  const sheet = env.spreadsheetNamed(SEPTEMBER).getSheetByName('Issues');
  assert.deepEqual(sheet.format(2, 9, 'dataValidation').values,
    ['New', 'Investigating', 'Fixed in …', 'Fixed in 1.10.1', 'Fixed in 1.9.4', "Won't fix"]);
});

test('tester names typed on Installs are kept and shown with the problems they hit', () => {
  const env = service();
  env.post(upload(env, [event(), crash()]));
  env.post(upload(env, [event()], { install: INSTALL_B }));
  env.context.rebuildIssues();
  typeInto(env, SEPTEMBER, 'Installs', { 'Diagnostics ID': INSTALL_A }, 'Tester name', 'Aysel');
  env.context.rebuildIssues();

  assert.equal(env.table(SEPTEMBER, 'Installs').find(row => row['Diagnostics ID'] === INSTALL_A)['Tester name'], 'Aysel');
  const issues = env.table(SEPTEMBER, 'Issues');
  assert.equal(issues.find(row => row.Signature === THROTTLED).Testers, 'Aysel + 1 more');
  assert.equal(issues.find(row => row.Signature === CRASH).Testers, 'Aysel');
  const top = overviewLines(env).find(line => line[0] === 'Gmail paused the connection: too many requests');
  assert.equal(top[4], 'Aysel + 1 more');
});

test('the team\'s notes and tester names carry into the next month\'s spreadsheet', () => {
  const env = service();
  env.post(upload(env, [event(), crash()]));
  env.context.rebuildIssues();
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Status', 'Investigating');
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Notes', 'Kamal can reproduce it');
  typeInto(env, SEPTEMBER, 'Installs', { 'Diagnostics ID': INSTALL_A }, 'Tester name', 'Kamal');

  env.setNow('2026-09-30T20:15:00Z'); // 00:15 on 1 October in Baku, when the nightly trigger runs
  env.context.dailyMaintenance();
  const october = 'FalconMail Diagnostics 2026-10';
  const crashRow = env.table(october, 'Issues').find(row => row.Signature === CRASH);
  assert.equal(crashRow.Status, 'Investigating');
  assert.equal(crashRow.Notes, 'Kamal can reproduce it');
  assert.equal(crashRow.Testers, 'Kamal');
  assert.equal(env.table(october, 'Installs')[0]['Tester name'], 'Kamal');
});

test('a quiet problem the team wrote about stays listed, others drop off after two months', () => {
  const env = service();
  env.post(upload(env, [event(), crash()]));
  env.context.rebuildIssues();
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Status', 'Fixed in 1.10.1');
  typeInto(env, SEPTEMBER, 'Installs', { 'Diagnostics ID': INSTALL_A }, 'Tester name', 'Kamal');

  env.setNow('2026-11-05T09:00:00Z');
  env.context.dailyMaintenance();
  const november = 'FalconMail Diagnostics 2026-11';
  const issues = env.table(november, 'Issues');
  assert.deepEqual(issues.map(row => [row.Signature, row.Status, row.Times]), [[CRASH, 'Fixed in 1.10.1', 1]]);
  assert.deepEqual(env.table(november, 'Installs').map(row => [row['Tester name'], row['Problems in last 7 days']]), [['Kamal', 0]]);
});

test('a batch resent after the cache forgot it is counted once', () => {
  const env = service();
  const sent = [event({ count: 3 })];
  env.post(upload(env, sent));
  env.cache.entries.clear();
  env.post(upload(env, sent));
  env.context.rebuildIssues();
  assert.equal(env.table(SEPTEMBER, 'Issues')[0].Times, 3);
});

test('a device clock running ahead never puts a problem in the future', () => {
  const env = service();
  env.post(upload(env, [event({ firstAt: '2027-01-01T00:00:00Z', lastAt: '2027-01-01T00:00:00Z' })]));
  env.context.rebuildIssues();
  const [row] = env.table(SEPTEMBER, 'Issues');
  assert.equal(row['Last seen'].toISOString(), '2026-09-24T08:00:00.000Z');
  assert.equal(row['First seen'].toISOString(), '2026-09-24T08:00:00.000Z');
});

test('Overview reads top to bottom: the last day, the last week, the top problems and versions', () => {
  const env = service();
  env.post(upload(env, [event({ count: 5 }), crash({ count: 2 }), event({ kind: 'launch', signature: 'App.launch' })]));
  env.post(upload(env, [event({ lastAt: '2026-09-21T10:00:00Z' })], { install: INSTALL_B, app: { version: '1.9.2', build: '99' } }));
  env.context.rebuildIssues();

  const lines = overviewLines(env);
  const labels = lines.map(line => line[0]);
  assert.equal(labels[0], 'FalconMail diagnostics');
  assert.equal(labels[1], 'Last updated 24 Sep 2026 12:00, Baku time. Covers reports since 1 Aug 2026.');
  const at = label => labels.indexOf(label);
  assert.ok(at('Last 24 hours') < at('Last 7 days'));
  assert.ok(at('Last 7 days') < at('Most frequent open problems'));
  assert.ok(at('Most frequent open problems') < at('Versions in use (last 7 days)'));

  const valueOf = label => lines[at(label)][1];
  assert.equal(valueOf('Problems reported'), 7);
  assert.equal(valueOf('Different problems'), 2);
  assert.equal(valueOf('Crashes'), 2);
  assert.equal(valueOf('Installs active'), 1);

  const week = lines.slice(at('Day') + 1, at('Day') + 8).map(line => line.slice(0, 4));
  assert.deepEqual(week.map(line => line[0]),
    ['Today', 'Yesterday', 'Tue 22 Sep', 'Mon 21 Sep', 'Sun 20 Sep', 'Sat 19 Sep', 'Fri 18 Sep']);
  assert.deepEqual(week[0], ['Today', 7, 2, 1]);
  assert.deepEqual(week[3], ['Mon 21 Sep', 1, 0, 1]);

  const top = lines.slice(at('Problem') + 1, at('Problem') + 3).map(line => [line[0], line[1], line[2], line[3]]);
  assert.deepEqual(top, [
    ['Gmail paused the connection: too many requests', 'Error', 6, 2],
    ['FalconMail crashed while opening a message', 'Crash', 2, 1],
  ]);
  const versions = lines.slice(at('Version') + 1).filter(line => line[0]).map(line => [line[0], line[1]]);
  assert.deepEqual(versions, [['1.10.0', 1], ['1.9.2', 1]]);

  const sheet = env.spreadsheetNamed(SEPTEMBER).getSheetByName('Overview');
  assert.equal(sheet.format(1, 1, 'fontSize'), 18);
  assert.equal(sheet.format(at('Last 24 hours') + 1, 1, 'fontWeight'), 'bold');
  assert.equal(sheet.format(at('Problem') + 3, 2, 'background'), '#F4C7C3', 'crashes are red');
  assert.equal(sheet.format(at('Crashes') + 1, 2, 'horizontalAlignment'), 'right');
});

test('Overview calls out a problem that came back after it was marked fixed', () => {
  const env = service();
  env.post(upload(env, [event(), crash()]));
  env.context.rebuildIssues();
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Status', 'Fixed in 1.10.1');
  env.context.rebuildIssues();
  assert.ok(!overviewLines(env).some(line => line[0] === 'Back after a fix'), 'nothing to call out yet');

  env.advance(60 * 1000);
  env.post(upload(env, [crash({ lastAt: '2026-09-24T08:00:00Z' })], { app: { version: '1.10.1', build: '130' } }));
  env.context.rebuildIssues();
  const lines = overviewLines(env);
  const section = lines.findIndex(line => line[0] === 'Back after a fix');
  assert.ok(section > 0);
  assert.deepEqual(lines[section + 2].slice(0, 5), ['FalconMail crashed while opening a message', 'Fixed in 1.10.1', '', '', '1.10.1']);
});

test('rebuilding before any report arrives leaves a tidy, empty summary', () => {
  const env = service();
  const labels = overviewLines(env).map(line => line[0]);
  assert.ok(labels.includes('No open problems.'));
  assert.ok(labels.includes('No installs reported in the last 7 days.'));
  assert.equal(env.table(SEPTEMBER, 'Issues').length, 0);
});
