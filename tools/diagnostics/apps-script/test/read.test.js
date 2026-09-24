'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { service, event, upload } = require('./harness');

function readKey(env) {
  return env.properties.getProperty('READ_KEY');
}

// Three uploads: three events in August, then two and four a minute apart in September.
function threeUploads() {
  const env = service({ now: '2026-08-20T10:00:00Z' });
  env.post(upload(env, [event({ title: 'a1' }), event({ title: 'a2' }), event({ title: 'a3' })]));
  env.setNow('2026-09-03T09:00:00Z');
  env.post(upload(env, [event({ title: 'b1' }), event({ title: 'b2' })]));
  env.advance(60 * 1000);
  env.post(upload(env, [event({ title: 'c1' }), event({ title: 'c2' }), event({ title: 'c3' }), event({ title: 'c4' })]));
  return env;
}

test('ping answers without a key', () => {
  const env = service();
  assert.deepEqual(env.get({ op: 'ping' }), { ok: true });
});

test('read and issues refuse a wrong key and say nothing else', () => {
  const env = service();
  env.post(upload(env, [event()]));
  for (const key of [undefined, '', 'wrong', env.properties.getProperty('INGEST_KEY')]) {
    assert.deepEqual(env.get({ op: 'read', key }), { ok: false, error: 'Not accepted' });
    assert.deepEqual(env.get({ op: 'issues', key }), { ok: false, error: 'Not accepted' });
  }
  assert.deepEqual(env.get({ op: 'delete', key: readKey(env) }), { ok: false, error: 'Unknown operation' });
});

test('read pages oldest first across months without losing or repeating a row', () => {
  const env = threeUploads();
  const first = env.get({ op: 'read', key: readKey(env), limit: '4' });
  assert.equal(first.ok, true);
  // a1–a3 from August, then b1 fills the page and b2 arrived with it, so it comes too.
  assert.deepEqual(first.rows.map(row => row.title), ['a1', 'a2', 'a3', 'b1', 'b2']);
  assert.equal(first.next, '2026-09-03T09:00:00.000Z');

  const second = env.get({ op: 'read', key: readKey(env), since: first.next, limit: '4' });
  assert.deepEqual(second.rows.map(row => row.title), ['c1', 'c2', 'c3', 'c4']);
  assert.equal(second.next, null);

  const none = env.get({ op: 'read', key: readKey(env), since: second.rows.at(-1).receivedAt });
  assert.deepEqual(none, { ok: true, rows: [], next: null });
});

test('a page never splits rows that arrived together', () => {
  const env = threeUploads();
  const page = env.get({ op: 'read', key: readKey(env), limit: '1' });
  assert.deepEqual(page.rows.map(row => row.title), ['a1', 'a2', 'a3']);
  assert.equal(page.next, '2026-08-20T10:00:00.000Z');
});

test('read without since returns everything up to the default limit', () => {
  const env = threeUploads();
  const page = env.get({ op: 'read', key: readKey(env) });
  assert.equal(page.rows.length, 9);
  assert.equal(page.next, null);
});

test('read refuses a since that is not a date', () => {
  const env = threeUploads();
  const answer = env.get({ op: 'read', key: readKey(env), since: 'yesterday' });
  assert.equal(answer.ok, false);
  assert.match(answer.error, /ISO 8601/);
});

test('rows come back with the contract\'s fields, as they were sent', () => {
  const env = service();
  const sent = event({
    kind: 'crash',
    title: '=HYPERLINK("https://example.com","Open")',
    message: '-5 retries left',
    count: 7,
    context: { callStackTree: { callStacks: [] } },
  });
  env.post(upload(env, [sent]));
  const [row] = env.get({ op: 'read', key: readKey(env) }).rows;
  assert.deepEqual(row, {
    receivedAt: '2026-09-24T08:00:00.000Z',
    title: '=HYPERLINK("https[:]//example[.]com","Open")',
    kind: 'crash',
    install: 'E621E1F8-C36C-495A-93FC-0C247A3E6E5F',
    version: '1.10.0',
    message: '-5 retries left',
    count: 7,
    firstAt: '2026-09-24T07:50:00.000Z',
    lastAt: '2026-09-24T07:55:00.000Z',
    area: 'IMAP',
    signature: 'IMAP.throttled@AccountSyncer.swift:131',
    build: '123',
    os: 'macOS 26.6 (25G5)',
    hw: 'MacBookPro18,3',
    account: JSON.stringify(sent.account),
    eventId: sent.id,
    context: '{"callStackTree":{"callStacks":[]}}',
  });
});

test('issues returns the Issues tab as JSON', () => {
  const env = service();
  env.post(upload(env, [event({ count: 3 }), event({ kind: 'crash', signature: 'Crash.SIGSEGV@Reader.swift:12', title: 'FalconMail crashed' })]));
  env.context.rebuildIssues();
  const answer = env.get({ op: 'issues', key: readKey(env) });
  assert.equal(answer.ok, true);
  assert.equal(answer.updatedAt, '2026-09-24T08:00:00.000Z');
  assert.deepEqual(answer.issues.map(issue => [issue.title, issue.kind, issue.times, issue.status]), [
    ['Gmail paused the connection: too many requests', 'error', 3, 'New'],
    ['FalconMail crashed', 'crash', 1, 'New'],
  ]);
  assert.equal(answer.issues[0].lastSeen, '2026-09-24T07:55:00.000Z');
  assert.equal(answer.issues[0].signature, 'IMAP.throttled@AccountSyncer.swift:131');
});

// Every page from `since` onwards, checking that each `next` moves forward.
function readAll(env, limit, since) {
  const titles = [];
  for (let pages = 0; pages < 50; pages++) {
    const page = env.get({ op: 'read', key: readKey(env), limit: String(limit), since });
    assert.equal(page.ok, true);
    titles.push(...page.rows.map(row => row.title));
    if (!page.next) return titles;
    if (since) assert.ok(Date.parse(page.next) > Date.parse(since), page.next + ' is not after ' + since);
    since = page.next;
  }
  assert.fail('read never finished');
}

test('read pages in arrival order even after someone sorts the Events tab', () => {
  const env = service();
  env.post(upload(env, [event({ title: 'old' })]));
  const cursor = new Date(env.nowMs + 30 * 1000).toISOString();
  const sent = [['n0'], ['n1', 'n1b'], ['n2'], ['n3'], ['n4'], ['n5'], ['n6']];
  sent.forEach((titles, i) => {
    env.advance(60 * 1000);
    env.post(upload(env, titles.map(title => event({ title, kind: i % 2 ? 'crash' : 'error' }))));
  });
  const expected = sent.flat();
  const sheet = env.spreadsheetNamed('FalconMail Diagnostics 2026-09').getSheetByName('Events');
  const rows = sheet.data.slice(1, sheet.getLastRow());
  const sorts = {
    'by Kind': (a, b) => String(a[2]).localeCompare(String(b[2])),
    'newest first': (a, b) => b[0] - a[0],
  };
  for (const [name, compare] of Object.entries(sorts)) {
    sheet.data.splice(1, rows.length, ...rows.slice().sort(compare));
    for (const limit of [1, 2, 1000]) {
      assert.deepEqual(readAll(env, limit, cursor), expected, name + ', limit ' + limit);
    }
    assert.deepEqual(readAll(env, 2), ['old'].concat(expected), name + ', from the start');
  }
});

test('a missing account or context comes back as JSON null, and context is always JSON', () => {
  const env = service();
  env.post(upload(env, [
    event({ title: 'none', account: null, context: null }),
    event({ title: 'text', context: 'plain text, not JSON' }),
    event({ title: 'json', context: '{"attempt":3}' }),
  ]));
  const rows = env.get({ op: 'read', key: readKey(env) }).rows;
  const byTitle = Object.fromEntries(rows.map(row => [row.title, row]));
  assert.equal(byTitle.none.account, 'null');
  assert.equal(byTitle.none.context, 'null');
  assert.equal(JSON.parse(byTitle.text.context), 'plain text, not JSON');
  assert.deepEqual(JSON.parse(byTitle.json.context), { attempt: 3 });
  rows.forEach(row => { JSON.parse(row.account); JSON.parse(row.context); });
  const [first] = env.table('FalconMail Diagnostics 2026-09', 'Events');
  assert.equal(first.Account, '', 'the sheet itself leaves an empty cell');
});

test('text starting with an apostrophe comes back as it was sent', () => {
  const env = service();
  env.post(upload(env, [event({ title: "'Sent' folder could not be found", signature: "'Sent'.missing@Folders.swift:9" })]));
  const [row] = env.get({ op: 'read', key: readKey(env) }).rows;
  assert.equal(row.title, "'Sent' folder could not be found");
  assert.equal(row.signature, "'Sent'.missing@Folders.swift:9");
  env.context.rebuildIssues();
  const [issue] = env.get({ op: 'issues', key: readKey(env) }).issues;
  assert.equal(issue.title, "'Sent' folder could not be found");
  assert.equal(issue.signature, "'Sent'.missing@Folders.swift:9");
});
