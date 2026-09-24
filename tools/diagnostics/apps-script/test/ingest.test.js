'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { service, event, upload, INSTALL_A, INSTALL_B } = require('./harness');

const SEPTEMBER = 'FalconMail Diagnostics 2026-09';

function eventsSheet(env, name = SEPTEMBER) {
  return env.spreadsheetNamed(name).getSheetByName('Events');
}

test('a valid upload is appended in one write and answered with the counts', () => {
  const env = service();
  const sheet = eventsSheet(env);
  const writesBefore = sheet.writes.length;
  const sent = [event(), event({ kind: 'crash', title: 'FalconMail crashed while opening a message' }), event({ kind: 'launch' })];

  assert.deepEqual(env.post(upload(env, sent)), { ok: true, accepted: 3, duplicates: 0 });
  assert.equal(sheet.writes.length - writesBefore, 1);
  assert.deepEqual(sheet.writes.at(-1), { row: 2, column: 1, rows: 3, columns: 17 });

  const [first, second, third] = env.table(SEPTEMBER, 'Events');
  assert.equal(first.Received.toISOString(), '2026-09-24T08:00:00.000Z');
  assert.equal(first.Problem, 'Gmail paused the connection: too many requests');
  assert.equal(first.Kind, 'Error');
  assert.equal(second.Kind, 'Crash');
  assert.equal(third.Kind, 'Launch');
  assert.equal(first['Diagnostics ID'], INSTALL_A);
  assert.equal(first['App version'], '1.10.0');
  assert.equal(first.Build, '123');
  assert.equal(first.macOS, 'macOS 26.6 (25G5)');
  assert.equal(first['Mac model'], 'MacBookPro18,3');
  assert.equal(first['Last seen'].toISOString(), '2026-09-24T07:55:00.000Z');
  assert.equal(first['Event ID'], sent[0].id);
  assert.deepEqual(JSON.parse(first.Context), { attempt: 3, mailbox: 'Inbox' });
});

test('only the four account fields of the contract are stored', () => {
  const env = service();
  const account = { provider: 'google', kind: 'workspace', host: 'imap.gmail.com', ref: '0badf00d', address: 'someone@example.com' };
  env.post(upload(env, [event({ account })]));
  const [row] = env.table(SEPTEMBER, 'Events');
  assert.deepEqual(JSON.parse(row.Account), { provider: 'google', kind: 'workspace', host: 'imap.gmail.com', ref: '0badf00d' });
  assert.ok(!JSON.stringify(env.table(SEPTEMBER, 'Events')).includes('someone@example.com'));
});

test('uploads with a wrong key, schema, size or event count are refused and nothing is written', () => {
  const env = service();
  const valid = upload(env, [event()]);
  const cases = [
    [Object.assign({}, valid, { key: 'wrong' }), 'Not accepted'],
    [Object.assign({}, valid, { key: undefined }), 'Not accepted'],
    [Object.assign({}, valid, { key: env.properties.getProperty('READ_KEY') }), 'Not accepted'],
    [Object.assign({}, valid, { schema: 2 }), /Unsupported schema/],
    [Object.assign({}, valid, { events: Array.from({ length: 201 }, () => event()) }), /More than 200 events/],
    [Object.assign({}, valid, { events: 'none' }), /no events list/],
    [Object.assign({}, valid, { install: 'short' }), /no valid install ID/],
    ['x'.repeat(256 * 1024 + 1), /larger than 256 KB/],
    // Counted in UTF-8 bytes, not characters: 131,073 two-byte characters are over 256 KB.
    [JSON.stringify(Object.assign({}, valid, { pad: 'é'.repeat(131073) })), /larger than 256 KB/],
    ['{not json', /not JSON/],
    ['', /empty/],
  ];
  for (const [body, error] of cases) {
    const answer = env.post(body);
    assert.equal(answer.ok, false);
    if (typeof error === 'string') assert.equal(answer.error, error);
    else assert.match(answer.error, error);
  }
  assert.equal(eventsSheet(env).getLastRow(), 1);
});

test('a resent upload is recognised by its event IDs', () => {
  const env = service();
  const first = [event(), event(), event()];
  env.post(upload(env, first));
  env.advance(60 * 1000);
  assert.deepEqual(env.post(upload(env, first)), { ok: true, accepted: 0, duplicates: 3 });
  assert.deepEqual(env.post(upload(env, [first[0], first[1], event()])), { ok: true, accepted: 1, duplicates: 2 });
  const repeated = event();
  assert.deepEqual(env.post(upload(env, [repeated, repeated])), { ok: true, accepted: 1, duplicates: 1 });
  assert.equal(eventsSheet(env).getLastRow(), 1 + 5);
});

test('event IDs are remembered for six hours in a handful of cache entries', () => {
  const env = service();
  const sent = Array.from({ length: 150 }, () => event());
  env.post(upload(env, sent));
  env.post(upload(env, Array.from({ length: 150 }, () => event())));
  const buckets = Array.from(env.cache.entries.keys()).filter(key => key.startsWith('seen:'));
  assert.ok(buckets.length <= 16, buckets.length + ' cache entries');

  env.advance(5 * 60 * 60 * 1000);
  assert.equal(env.post(upload(env, sent.slice(0, 1))).duplicates, 1);
  env.advance(2 * 60 * 60 * 1000);
  assert.equal(env.post(upload(env, sent.slice(1, 2))).accepted, 1, 'forgotten after six hours');
});

test('each install may upload 60 times an hour', () => {
  const env = service();
  for (let i = 0; i < 60; i++) assert.equal(env.post(upload(env, [event()])).ok, true, 'upload ' + (i + 1));
  const refused = env.post(upload(env, [event()]));
  assert.equal(refused.ok, false);
  assert.match(refused.error, /Too many uploads from this install/);
  assert.equal(env.post(upload(env, [event()], { install: INSTALL_B })).ok, true, 'other installs are not held back');
  env.advance(60 * 60 * 1000);
  assert.equal(env.post(upload(env, [event()])).ok, true, 'allowed again the next hour');
});

test('the daily limit turns uploads away once 5,000 events are filed that day', () => {
  const env = service();
  env.properties.setProperty('EVENTS_ON_2026-09-24', '4999');
  const refused = env.post(upload(env, [event(), event()]));
  assert.equal(refused.ok, false);
  assert.match(refused.error, /daily limit/);
  assert.equal(env.post(upload(env, [event()])).accepted, 1);
  assert.equal(env.properties.getProperty('EVENTS_ON_2026-09-24'), '5000');
  env.advance(24 * 60 * 60 * 1000);
  assert.equal(env.post(upload(env, [event(), event()])).accepted, 2, 'a new day in Baku starts a new count');
});

test('a busy lock is reported so the app keeps its events and tries again', () => {
  const env = service();
  const sent = [event(), event()];
  env.lockAvailable = false;
  const busy = env.post(upload(env, sent));
  assert.equal(busy.ok, false);
  assert.match(busy.error, /busy/);
  assert.equal(eventsSheet(env).getLastRow(), 1);
  env.lockAvailable = true;
  assert.equal(env.post(upload(env, sent)).accepted, 2);
});

test('a failure while writing answers ok:false and the events are not marked as seen', () => {
  const env = service();
  const sheet = eventsSheet(env);
  const sent = [event()];
  const getRange = sheet.getRange;
  sheet.getRange = () => { throw new Error('Service Spreadsheets failed while accessing document'); };
  const failed = env.post(upload(env, sent));
  assert.deepEqual(failed, { ok: false, error: 'The diagnostics service failed; try again later' });
  assert.ok(env.errors.some(line => line.includes('Service Spreadsheets failed')));
  sheet.getRange = getRange;
  assert.equal(env.post(upload(env, sent)).accepted, 1);
});

test('text Sheets would run as a formula is stored as plain text', () => {
  const env = service();
  const dangerous = event({
    title: '=HYPERLINK("https://example.com","Open")',
    message: '+SUM(A1:A9)',
    area: '-1',
    signature: '@IMAP.bad',
    context: '=IMPORTDATA("https://example.com")',
  });
  env.post(upload(env, [dangerous], { hw: '=1+1' }));
  const sheet = eventsSheet(env);
  assert.deepEqual(sheet.formulaCells, []);
  const [row] = env.table(SEPTEMBER, 'Events');
  assert.equal(row.Problem, '=HYPERLINK("https[:]//example[.]com","Open")');
  assert.equal(row.Message, dangerous.message);
  assert.equal(row.Signature, dangerous.signature);
});

test('long text is cut to the contract\'s limits and every cell stays under 50,000 characters', () => {
  const env = service();
  const huge = event({
    title: 'T'.repeat(300),
    message: 'M'.repeat(5000),
    context: { dump: 'C'.repeat(60000) },
    signature: 'S'.repeat(400),
  });
  const body = upload(env, [huge]);
  assert.ok(Buffer.byteLength(JSON.stringify(body)) < 256 * 1024);
  assert.equal(env.post(body).accepted, 1);
  const [row] = env.table(SEPTEMBER, 'Events');
  assert.equal(row.Problem.length, 120);
  assert.equal(row.Message.length, 2000);
  assert.ok(row.Message.endsWith('…'));
  assert.equal(row.Signature.length, 300);
  const context = JSON.parse(row.Context);
  assert.ok(row.Context.length <= 16 * 1024);
  assert.equal(context.truncated, true, 'too large to keep whole, and still JSON');
  assert.equal(context.size, JSON.stringify(huge.context).length);
  assert.ok(context.start.startsWith('{"dump":"CCC'));
});

test('events that cannot be filed are skipped and counted, the rest are kept', () => {
  const env = service();
  const answer = env.post(upload(env, [event(), event({ id: undefined }), event({ kind: 5 }), event({ signature: '  ' }), 'nonsense']));
  assert.deepEqual(answer, { ok: true, accepted: 1, duplicates: 0, invalid: 4 });
  assert.equal(eventsSheet(env).getLastRow(), 2);
});

test('an upload with no events is accepted without touching the spreadsheet', () => {
  const env = service();
  const writes = eventsSheet(env).writes.length;
  assert.deepEqual(env.post(upload(env, [])), { ok: true, accepted: 0, duplicates: 0 });
  assert.equal(eventsSheet(env).writes.length, writes);
});

test('a new month in Baku starts a new spreadsheet in the folder, shared with the domain', () => {
  const env = service();
  env.post(upload(env, [event()]));
  env.setNow('2026-09-30T19:59:00Z'); // 23:59 in Baku: still September
  env.post(upload(env, [event()]));
  env.setNow('2026-09-30T20:30:00Z'); // 00:30 on 1 October in Baku
  env.post(upload(env, [event()]));

  const october = env.spreadsheetNamed('FalconMail Diagnostics 2026-10');
  assert.ok(october);
  assert.equal(october.file.parent, env.properties.getProperty('FOLDER_ID'));
  assert.deepEqual(october.file.sharing, { access: 'DOMAIN', permission: 'VIEW' });
  assert.deepEqual(october.getSheets().map(sheet => sheet.getName()), ['Overview', 'Issues', 'Installs', 'Events']);
  assert.equal(eventsSheet(env).getLastRow(), 3);
  assert.equal(eventsSheet(env, 'FalconMail Diagnostics 2026-10').getLastRow(), 2);
  const closed = env.spreadsheetNamed(SEPTEMBER).getSheetByName('Overview').value(2, 1);
  assert.match(closed, /^Closed\. Newer reports are in FalconMail Diagnostics 2026-10: https:/);
});

test('a month that outgrows its size budget carries on in a part 2', () => {
  const env = service();
  env.properties.setProperty('SHEET_CHARS', String(env.value('SPREADSHEET_CHAR_BUDGET') - 10));
  env.post(upload(env, [event()]));
  const part2 = env.spreadsheetNamed('FalconMail Diagnostics 2026-09 part 2');
  assert.ok(part2);
  assert.equal(part2.getSheetByName('Events').getLastRow(), 2);
  assert.equal(eventsSheet(env).getLastRow(), 1);
});

test('the Events tab grows past its first thousand rows and keeps its formatting', () => {
  const env = service();
  for (let batch = 0; batch < 6; batch++) {
    env.post(upload(env, Array.from({ length: 200 }, () => event()), { install: batch % 2 ? INSTALL_A : INSTALL_B }));
    env.advance(1000);
  }
  const sheet = eventsSheet(env);
  assert.equal(sheet.getLastRow(), 1201);
  assert.ok(sheet.getMaxRows() >= 1201);
  const bottom = sheet.getMaxRows();
  assert.equal(sheet.getFilter().getRange().getLastRow(), bottom);
  assert.ok(sheet.getConditionalFormatRules().every(rule => rule.ranges.every(range => range.endsWith(String(bottom)))));
  assert.equal(sheet.format(1201, 1, 'numberFormat'), 'd mmm yyyy hh:mm');
});

test('one install cannot use up the day on its own: 1,000 events each, counted under the lock', () => {
  const env = service();
  for (let i = 0; i < 5; i++) {
    assert.equal(env.post(upload(env, Array.from({ length: 200 }, () => event()))).accepted, 200, 'upload ' + (i + 1));
    env.advance(1000);
  }
  const refused = env.post(upload(env, [event()]));
  assert.equal(refused.ok, false);
  assert.match(refused.error, /This install has sent as much as it may today/);
  assert.equal(env.post(upload(env, [event({ kind: 'crash' })], { install: INSTALL_B })).accepted, 1, 'others still get through');
  assert.deepEqual(JSON.parse(env.properties.getProperty('INSTALLS_ON_2026-09-24')), { [INSTALL_A]: 1000, [INSTALL_B]: 1 });
  env.setNow('2026-09-24T20:30:00Z'); // 00:30 on the 25th in Baku
  assert.equal(env.post(upload(env, [event()])).accepted, 1, 'a new day starts a new count');
});

test('the day\'s text is capped as well as its events, so large reports cannot fill Drive', () => {
  const env = service();
  env.post(upload(env, [event()]));
  const used = Number(env.properties.getProperty('CHARS_ON_2026-09-24'));
  assert.ok(used > 0);
  env.properties.setProperty('CHARS_ON_2026-09-24', String(env.value('MAX_CHARS_PER_DAY') - 10));
  const refused = env.post(upload(env, [event()], { install: INSTALL_B }));
  assert.equal(refused.ok, false);
  assert.match(refused.error, /daily limit/);
  assert.equal(eventsSheet(env).getLastRow(), 2);
});

test('a flood of made-up install IDs keeps the per-install counts inside one property', () => {
  const env = service();
  const counts = {};
  for (let i = 0; i < 400; i++) counts['FFFFFFFF-0000-4000-8000-' + String(i).padStart(12, '0')] = 1;
  counts[INSTALL_A] = 900;
  const text = env.context.installCountsText_(counts);
  assert.ok(text.length <= 8000, text.length + ' characters');
  assert.equal(JSON.parse(text)[INSTALL_A], 900, 'the busiest install stays counted');
});

test('control characters never reach the spreadsheet, and line breaks in a message stay', () => {
  const env = service();
  env.post(upload(env, [event({
    title: '\u001b]0;owned\u0007\u001b[2KGmail paused',
    message: 'first line\r\nsecond\u001b[1A\u001b[2K line\u0085',
    area: 'IMAP\u0000',
    signature: 'IMAP.x\u001b[8m@A.swift:1',
    account: { provider: 'google', kind: 'gmail', host: 'imap.gmail.com\u0007', ref: '1a2b3c4d' },
  })], { app: { version: '1.10\u001b[5m', build: '1' } }));
  const [row] = env.table(SEPTEMBER, 'Events');
  for (const value of Object.values(row)) {
    if (typeof value === 'string') assert.doesNotMatch(value, /[\u0000-\u0008\u000B-\u001F\u007F-\u009F]/);
  }
  assert.equal(row.Problem, ']0;owned[2KGmail paused');
  assert.equal(row.Message, 'first line\nsecond[1A[2K line');
  assert.equal(row['App version'], '1.10[5m');
  assert.equal(JSON.parse(row.Account).host, 'imap.gmail.com');
});

test('web addresses in titles and messages are kept readable but not clickable, and counts are capped', () => {
  const env = service();
  env.post(upload(env, [event({
    title: 'FalconMail must be updated: install it from https://falconmail-update.example/get',
    message: 'See HTTP://evil.example/x or www.evil.example/y; the server mail.your-server.de refused',
    count: 1e12,
  })]));
  const [row] = env.table(SEPTEMBER, 'Events');
  assert.equal(row.Problem, 'FalconMail must be updated: install it from https[:]//falconmail-update[.]example/get');
  assert.equal(row.Message, 'See HTTP[:]//evil[.]example/x or www[.]evil[.]example/y; the server mail.your-server.de refused');
  assert.equal(row.Times, 10000);
});

test('text starting with an apostrophe keeps it', () => {
  const env = service();
  env.post(upload(env, [event({ title: "'Sent' folder could not be found", message: "'quoted' reply" })]));
  const [row] = env.table(SEPTEMBER, 'Events');
  assert.equal(row.Problem, "'Sent' folder could not be found");
  assert.equal(row.Message, "'quoted' reply");
});
