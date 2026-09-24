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
    title: sent.title,
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
