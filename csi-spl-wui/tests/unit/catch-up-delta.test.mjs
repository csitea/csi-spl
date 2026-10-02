/**
 * R2-2 (db payload audit round 2): reconnect catch-up as a delta. The channel
 * store tells the hub the newest cursor it holds plus its reaction counts,
 * and merges the answer by REPLACING held rows - so an edit, kind change,
 * reaction (added or removed) or move made while the socket was down shows,
 * and archived / moved-out rows leave. The old merge (mergePage) kept every
 * held row as it was; the "old merge" controls below pin that it fails these.
 */
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { CATCH_UP_RX_MAX, catchUpQuery, cursorTime, mergeCatchUp, mergePage } from '../../src/utils/channel-feed.mjs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const here = dirname(fileURLToPath(import.meta.url))

const row = (id, task, at, extra = {}) => ({ msg_id: id, task_id: task, ts: at, received_at: at, cursor: `c-${id}`, body: `line ${id}`, reactions: [], ...extra })
const held = () => [
  row('a1', 'A', '2026-10-02T10:00:00.1Z'),
  row('a2', 'A', '2026-10-02T10:00:01.25Z', { reactions: [{ emoji: '👀', actors: ['HUM-1', 'HUM-2'] }] }),
  row('b1', 'B', '2026-10-02T10:00:02Z'),
  row('b2', 'B', '2026-10-02T10:00:02.5Z'),
]

describe('catchUpQuery: what a reconnect tells the hub', () => {
  it('since = the cursor of the newest row by receive time (not by string order), rx = held reaction rows', () => {
    const q = catchUpQuery(held())
    assert.equal(q.since, 'c-b2')
    assert.equal(q.sinceAt, '2026-10-02T10:00:02.5Z')
    assert.deepEqual(q.rx, ['a2~2'])
  })
  it('a later sync cursor from the last catch-up wins; an earlier one does not; sinceAt stays the newest row', () => {
    const cur = (at) => Buffer.from(`${at}|sync`).toString('base64url')
    assert.equal(cursorTime(cur('2026-10-02T10:00:03Z')), Date.parse('2026-10-02T10:00:03Z'))
    assert.equal(cursorTime('not a cursor'), 0)
    const later = catchUpQuery(held(), cur('2026-10-02T10:05:00Z'))
    assert.equal(later.since, cur('2026-10-02T10:05:00Z'))
    assert.equal(later.sinceAt, '2026-10-02T10:00:02.5Z')
    assert.equal(catchUpQuery(held(), cur('2026-10-02T09:00:00Z')).since, 'c-b2')
  })
  it('pending sends and topic rows never set the cursor', () => {
    const rows = [...held(), row('p', 'B', '2026-10-02T11:00:00Z', { pending: true }), row('t', 't', '2026-10-02T12:00:00Z', { topic_row: true })]
    assert.equal(catchUpQuery(rows).since, 'c-b2')
  })
  it('null (= the full page) with no cursor held, or more reacted rows than the hub takes', () => {
    assert.equal(catchUpQuery([]), null)
    assert.equal(catchUpQuery([{ msg_id: 'x', task_id: 'X' }]), null)
    const many = Array.from({ length: CATCH_UP_RX_MAX + 1 }, (_, i) => row(`r${i}`, 'R', '2026-10-02T10:00:00Z', { reactions: [{ emoji: '👍', actors: ['HUM-1'] }] }))
    assert.equal(catchUpQuery(many), null)
    assert.equal(catchUpQuery(many.slice(1)).rx.length, CATCH_UP_RX_MAX)
  })
})

describe('mergeCatchUp: changes made in the gap show after the reconnect', () => {
  const sinceAt = '2026-10-02T10:00:02.5Z'
  it('an edit replaces the held row in place (old merge: kept the stale body)', () => {
    const fresh = [{ ...row('a1', 'A', '2026-10-02T10:00:00.1Z'), body: 'edited', edited_at: '2026-10-02T10:05:00Z' }]
    const out = mergeCatchUp(held(), fresh, { delta: true, sinceAt })
    assert.equal(out[0].body, 'edited')
    assert.equal(out[0].edited_at, '2026-10-02T10:05:00Z')
    assert.deepEqual(out.map((m) => m.msg_id), ['a1', 'a2', 'b1', 'b2'])
    assert.equal(mergePage(held(), fresh)[0].body, 'line a1', 'old merge')
  })
  it('a kind change and a reaction removed land the same way', () => {
    const fresh = [row('a2', 'A', '2026-10-02T10:00:01.25Z', { kind: 'blocker', reactions: [] })]
    const out = mergeCatchUp(held(), fresh, { delta: true, sinceAt })
    assert.equal(out[1].kind, 'blocker')
    assert.deepEqual(out[1].reactions, [])
    assert.deepEqual(mergePage(held(), fresh)[1].reactions, [{ emoji: '👀', actors: ['HUM-1', 'HUM-2'] }], 'old merge')
  })
  it('a reaction added lands', () => {
    const fresh = [row('b1', 'B', '2026-10-02T10:00:02Z', { reactions: [{ emoji: '👍', actors: ['HUM-3'] }] })]
    assert.deepEqual(mergeCatchUp(held(), fresh, { delta: true, sinceAt })[2].reactions, [{ emoji: '👍', actors: ['HUM-3'] }])
  })
  it('a message moved into another held topic takes that topic', () => {
    const out = mergeCatchUp(held(), [row('b2', 'A', '2026-10-02T10:00:02.5Z')], { delta: true, sinceAt })
    assert.equal(out[3].task_id, 'A')
    assert.equal(mergePage(held(), [row('b2', 'A', '2026-10-02T10:00:02.5Z')])[3].task_id, 'B', 'old merge')
  })
  it('a delta drops every row of an archived topic and each moved-out row', () => {
    const out = mergeCatchUp(held(), [], { delta: true, goneTasks: ['B'], goneMsgs: ['a1'], sinceAt })
    assert.deepEqual(out.map((m) => m.msg_id), ['a2'])
  })
  it('a delta adds new rows and rows of held topics, never an old topic the feed did not load', () => {
    const fresh = [row('n1', 'N', '2026-10-02T10:10:00Z'), row('a0', 'A', '2026-10-01T09:00:00Z'), row('o1', 'O', '2026-10-01T09:00:00Z')]
    const out = mergeCatchUp(held(), fresh, { delta: true, sinceAt })
    assert.deepEqual(out.map((m) => m.msg_id), ['a1', 'a2', 'b1', 'b2', 'n1', 'a0'])
  })
  it('the full page (no delta) adds every row and still replaces held ones', () => {
    const fresh = [{ ...row('a1', 'A', '2026-10-02T10:00:00.1Z'), body: 'edited' }, row('o1', 'O', '2026-10-01T09:00:00Z')]
    const out = mergeCatchUp(held(), fresh, { delta: false, goneTasks: ['B'] })
    assert.equal(out[0].body, 'edited')
    assert.deepEqual(out.map((m) => m.msg_id), ['a1', 'a2', 'o1'])
  })
  it('a pending row is replaced whole by its stored copy', () => {
    const out = mergeCatchUp([row('p', 'A', '2026-10-02T10:00:00Z', { pending: true, local: 1 })], [row('p', 'A', '2026-10-02T10:00:00Z')], {})
    assert.equal(out[0].pending, undefined)
    assert.equal(out[0].local, undefined)
  })
})

describe('the client sends since= and rx=, and reads the delta answer', () => {
  const fetchFor = (calls, body) => async (url) => {
    calls.push(url)
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => body }
  }
  it('listMessages({ changedSince, rx }) -> one topics read with since= and rx=, delta and gone lists back', async () => {
    const calls = []
    const body = { topics: [], next: null, delta: true, gone_tasks: ['B'], gone_msgs: ['a1'], sync: 'c-sync' }
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: fetchFor(calls, body) })
    const page = await c.listMessages({ channel: 'feedback', limit: 50, changedSince: 'c-b2', rx: ['a2~2'] })
    const q = new URL(calls[0]).searchParams
    assert.equal(calls.length, 1)
    assert.equal(q.get('since'), 'c-b2')
    assert.deepEqual(q.getAll('rx'), ['a2~2'])
    assert.equal(q.get('per_topic'), '50')
    assert.equal(page.delta, true)
    assert.deepEqual(page.goneTasks, ['B'])
    assert.deepEqual(page.goneMsgs, ['a1'])
    assert.equal(page.sync, 'c-sync')
  })
  it('a hub without since= (no delta key) reads as the full page; no since= without changedSince', async () => {
    const calls = []
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn: fetchFor(calls, { topics: [], next: null }) })
    const page = await c.listMessages({ channel: 'feedback', limit: 50 })
    assert.equal(new URL(calls[0]).searchParams.get('since'), null)
    assert.equal(page.delta, false)
    assert.deepEqual(page.goneTasks, [])
  })
  it('the channel store catch-up sends its catchUpQuery and merges with mergeCatchUp', () => {
    const src = readFileSync(join(here, '../../src/stores/channel.ts'), 'utf8')
    const body = src.slice(src.indexOf('async function catchUp()'), src.indexOf('function applyEdited'))
    assert.match(body, /catchUpQuery\(messages\.value, catchUpSync\.key === key \? catchUpSync\.cursor : ''\)/)
    assert.match(body, /catchUpSync = \{ key, cursor: page\.sync \|\| '' \}/)
    assert.match(body, /changedSince: q\.since, rx: q\.rx/)
    assert.match(body, /mergeCatchUp\(/)
    assert.doesNotMatch(body, /mergePage\(/)
  })
})
