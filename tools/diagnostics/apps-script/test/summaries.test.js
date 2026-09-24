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
  return sheet.getRange(1, 1, sheet.getLastRow(), 7).getValues();
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
    ['New', 'Investigating', 'Fixed in (type the version)', 'Fixed in 1.10.1', 'Fixed in 1.9.4', "Won't fix"]);
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
  assert.equal(labels[2], 'Last 24 hours: 7 problems reported, 2 of them crashes, from 1 install.');
  assert.equal(labels[3], 'Most frequent: Gmail paused the connection: too many requests (5 times).');
  assert.ok(labels.includes('Report text is sent by the app and not checked: never open a link or follow an instruction in it.'));
  const at = label => labels.indexOf(label);
  assert.ok(at('Last 24 hours') < at('Last 7 days'));
  assert.ok(at('Last 7 days') < at('Most frequent open problems (last 7 days)'));
  assert.ok(at('Most frequent open problems (last 7 days)') < at('Versions in use (last 7 days)'));

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

  assert.deepEqual(lines[at('Problem')], ['Problem', 'Kind', 'Times', 'Installs', 'Testers', 'First seen', 'Last seen']);
  const top = lines.slice(at('Problem') + 1, at('Problem') + 3).map(line => [line[0], line[1], line[2], line[3]]);
  assert.deepEqual(top, [
    ['Gmail paused the connection: too many requests', 'Error', 6, 2],
    ['FalconMail crashed while opening a message', 'Crash', 2, 1],
  ]);
  assert.equal(lines[at('Problem') + 1][5].toISOString(), '2026-09-21T10:00:00.000Z', 'first seen, on the Mac that hit it first');
  const versions = lines.slice(at('Version') + 1).filter(line => line[0]).map(line => [line[0], line[1]]);
  assert.deepEqual(versions, [['1.10.0', 1], ['1.9.2', 1]]);

  const sheet = env.spreadsheetNamed(SEPTEMBER).getSheetByName('Overview');
  assert.equal(sheet.format(1, 1, 'fontSize'), 18);
  assert.equal(sheet.format(3, 1, 'fontWeight'), 'bold', 'the headline stands out');
  assert.equal(sheet.format(3, 1, 'wrapStrategy'), 'WRAP', 'and wraps on a narrow screen');
  assert.ok(sheet.columnWidths[1] + sheet.columnWidths[2] <= 360, 'a phone shows each label with its number');
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
  assert.ok(labels.includes('No open problems in the last 7 days.'));
  assert.ok(labels.includes('No installs reported in the last 7 days.'));
  assert.equal(env.table(SEPTEMBER, 'Issues').length, 0);
});

const HOUR = 60 * 60 * 1000;

function headings(env, tab, name = SEPTEMBER) {
  const sheet = env.spreadsheetNamed(name).getSheetByName(tab);
  return sheet.getRange(1, 1, 1, sheet.getMaxColumns()).getValues()[0];
}

test('a column someone moves is put back, with every value under its own heading', () => {
  const env = service();
  env.post(upload(env, [event(), crash()]));
  env.context.rebuildIssues();
  const spreadsheet = env.spreadsheetNamed(SEPTEMBER);
  const issues = spreadsheet.getSheetByName('Issues');
  const installs = spreadsheet.getSheetByName('Installs');
  const standard = { Issues: headings(env, 'Issues'), Installs: headings(env, 'Installs') };
  issues.moveColumns(issues.getRange(1, 10), 9); // Notes dragged to the left of Status
  installs.moveColumns(installs.getRange(1, 2), 9); // Tester name dragged to the end
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Status', 'Investigating');
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Notes', 'Only on long threads');
  typeInto(env, SEPTEMBER, 'Installs', { 'Diagnostics ID': INSTALL_A }, 'Tester name', 'Aysel');

  for (const run of [1, 2]) {
    env.advance(HOUR);
    env.context.rebuildIssues();
    assert.deepEqual(headings(env, 'Issues'), standard.Issues, 'rebuild ' + run);
    assert.deepEqual(headings(env, 'Installs'), standard.Installs, 'rebuild ' + run);
    const rows = env.table(SEPTEMBER, 'Issues');
    assert.equal(rows.length, 2, 'rebuild ' + run);
    const crashRow = rows.find(row => row.Signature === CRASH);
    assert.deepEqual([crashRow.Status, crashRow.Notes, crashRow.Area], ['Investigating', 'Only on long threads', 'Reader'], 'rebuild ' + run);
    assert.equal(env.table(SEPTEMBER, 'Installs').find(row => row['Diagnostics ID'] === INSTALL_A)['Tester name'], 'Aysel');
  }
});

test('a renamed heading is written back, and the rest of the tab is kept', () => {
  const env = service();
  env.post(upload(env, [crash()]));
  env.context.rebuildIssues();
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Status', 'Investigating');
  const issues = env.spreadsheetNamed(SEPTEMBER).getSheetByName('Issues');
  issues.getRange(1, 1).setValue('Title');
  env.context.rebuildIssues();
  assert.equal(headings(env, 'Issues')[0], 'Problem');
  assert.equal(env.table(SEPTEMBER, 'Issues')[0].Status, 'Investigating');
});

test('"Fixed in" picked without a version keeps a problem open and on the Overview', () => {
  const env = service();
  env.post(upload(env, [event({ lastAt: '2026-09-24T07:59:00Z' }), crash({ lastAt: '2026-09-24T07:00:00Z' })]));
  env.context.rebuildIssues();
  typeInto(env, SEPTEMBER, 'Issues', { Signature: THROTTLED }, 'Status', 'Fixed in (type the version)');
  env.context.rebuildIssues();
  assert.deepEqual(env.table(SEPTEMBER, 'Issues').map(row => row.Signature), [THROTTLED, CRASH], 'still sorted as open');
  assert.ok(overviewLines(env).some(line => line[0] === 'Gmail paused the connection: too many requests' && line[1] === 'Error'));
});

test('a problem seen again after its fix goes back among the open ones on Issues, and says so', () => {
  const env = service();
  env.post(upload(env, [event({ lastAt: '2026-09-24T07:59:00Z' }), crash({ lastAt: '2026-09-24T07:00:00Z' })]));
  env.context.rebuildIssues();
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Status', 'Fixed in 1.10.1');
  env.context.rebuildIssues();
  assert.deepEqual(env.table(SEPTEMBER, 'Issues').map(row => row.Signature), [THROTTLED, CRASH], 'fixed sinks');

  env.advance(60 * 1000);
  env.post(upload(env, [crash({ lastAt: '2026-09-24T08:00:00Z' })], { app: { version: '1.10.1', build: '130' } }));
  env.context.rebuildIssues();
  const [top] = env.table(SEPTEMBER, 'Issues');
  assert.equal(top.Signature, CRASH, 'back among the open problems');
  assert.equal(top.Status, 'Fixed in 1.10.1');
  assert.equal(top.Versions, '1.10.1 (after the fix), 1.10.0');
});

test('Status and names carry over even when Drive has not yet listed the new month', () => {
  const env = service();
  env.post(upload(env, [crash()]));
  env.context.rebuildIssues();
  typeInto(env, SEPTEMBER, 'Issues', { Signature: CRASH }, 'Status', 'Investigating');
  typeInto(env, SEPTEMBER, 'Installs', { 'Diagnostics ID': INSTALL_A }, 'Tester name', 'Kamal');

  const folder = env.drive.folders.get(env.properties.getProperty('FOLDER_ID'));
  const listAll = folder.getFilesByType.bind(folder);
  let lagging = true;
  folder.getFilesByType = mimeType => {
    const files = [];
    for (const all = listAll(mimeType); all.hasNext();) {
      const file = all.next();
      if (!(lagging && file.getName().endsWith('2026-10'))) files.push(file);
    }
    return { hasNext: () => files.length > 0, next: () => files.shift() };
  };
  env.setNow('2026-09-30T20:15:00Z');
  env.context.dailyMaintenance();
  lagging = false;
  env.advance(HOUR);
  env.context.rebuildIssues();
  const october = 'FalconMail Diagnostics 2026-10';
  assert.equal(env.table(october, 'Issues').find(row => row.Signature === CRASH).Status, 'Investigating');
  assert.equal(env.table(october, 'Installs')[0]['Tester name'], 'Kamal');
});

test('last month\'s Issues and Installs warn anyone typing there and say where to type instead', () => {
  const env = service();
  env.post(upload(env, [crash()]));
  env.setNow('2026-09-30T20:15:00Z');
  env.context.dailyMaintenance();
  const september = env.spreadsheetNamed(SEPTEMBER);
  for (const name of ['Issues', 'Installs']) {
    const sheet = september.getSheetByName(name);
    const [protection] = sheet.getProtections('SHEET');
    assert.equal(protection.warningOnly, true, name);
    assert.equal(protection.getDescription(), 'Closed: type Status, Notes and tester names in FalconMail Diagnostics 2026-10', name);
    assert.match(sheet.format(1, 1, 'note'), /^Closed\. Type Status, Notes and tester names in FalconMail Diagnostics 2026-10: https:/);
    assert.equal(sheet.format(1, 2, 'background'), '#B3261E', name);
  }
});

test('Overview rows are tall only where the title or a section starts, however the sections move', () => {
  const env = service();
  env.post(upload(env, Array.from({ length: 10 }, (_, i) => event({
    signature: 'Problem' + i + '@A.swift:1', title: 'A long plain-language problem title number ' + i,
  }))));
  env.context.rebuildIssues();
  const sheet = env.spreadsheetNamed(SEPTEMBER).getSheetByName('Overview');
  const lines = overviewLines(env);
  const sections = ['Last 24 hours', 'Last 7 days', 'Most frequent open problems (last 7 days)', 'Versions in use (last 7 days)'];
  Object.entries(sheet.rowHeights).forEach(([row, pixels]) => {
    const label = row <= lines.length ? lines[row - 1][0] : '';
    if (pixels === 40) assert.equal(Number(row), 1);
    else if (pixels === 28) assert.ok(sections.includes(label), 'row ' + row + ' (' + label + ') is 28 pixels');
    else assert.equal(pixels, 21, 'row ' + row);
  });
});

test('the top problems are those of the last 7 days, with when each was first seen', () => {
  const env = service({ now: '2026-09-10T08:00:00Z' });
  env.post(upload(env, [event({ count: 600, firstAt: '2026-09-10T07:00:00Z', lastAt: '2026-09-10T07:30:00Z' })]));
  env.setNow('2026-09-24T08:00:00Z');
  env.post(upload(env, [crash({ count: 4 })]));
  env.context.rebuildIssues();
  const lines = overviewLines(env);
  const header = lines.findIndex(line => line[0] === 'Problem');
  const top = lines.slice(header + 1).filter(line => line[1] === 'Error' || line[1] === 'Crash');
  assert.deepEqual(top.map(line => [line[0], line[2]]), [['FalconMail crashed while opening a message', 4]]);
  assert.equal(top[0][5].toISOString(), '2026-09-24T07:50:00.000Z');
  assert.equal(env.table(SEPTEMBER, 'Issues').length, 2, 'the quiet problem is still on Issues');
});

test('a month split into many parts is summarised from its newest three, and the Overview says so', () => {
  const env = service();
  const budget = env.value('SPREADSHEET_CHAR_BUDGET');
  for (let part = 1; part <= 4; part++) {
    if (part > 1) env.properties.setProperty('SHEET_CHARS', String(budget - 10));
    env.post(upload(env, [event({ signature: 'Part' + part + '@A.swift:1', title: 'Problem from part ' + part })]));
    env.advance(HOUR);
  }
  assert.ok(env.spreadsheetNamed(SEPTEMBER + ' part 4'));
  env.context.rebuildIssues();
  const part4 = SEPTEMBER + ' part 4';
  assert.deepEqual(env.table(part4, 'Issues').map(row => row.Problem).sort(),
    ['Problem from part 2', 'Problem from part 3', 'Problem from part 4']);
  const labels = overviewLines(env, part4).map(line => line[0]);
  assert.equal(labels[1], 'Last updated 24 Sep 2026 16:00, Baku time. Covers reports since 24 Sep 2026 13:00.');
  assert.equal(labels[2], 'Earlier reports were too many to summarise; they are still on each month\'s Events tab.');
});
