// CLE-3425 — "newest first EVERYWHERE, and a new item pops to the top without
// a refresh" (the owner's order of 2026-09-20, extending 013 US7 / CLE-3412).
//
// 013 proved it for one list: the messages of the open view. This suite covers
// the lists it did not — the channel / DM thread cards ordered by their LAST
// activity, the sidebar channel list, the sidebar DM list — plus the DOM
// contract the live audit reads (`data-ts` on every row of every list, so the
// rendered order can be checked against the clock rather than against a guess).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  channelActivity,
  channelView,
  dmActivity,
  feedRow,
  mergeLive,
  orderChannels,
  orderPeers,
  threadCards,
} from '../../src/utils/channel-feed.mjs'
import { activityOf, newestActivityFirst } from '../../src/utils/feed.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (p) => readFileSync(join(SRC, p), 'utf8')
const ids = (rows) => rows.map((r) => r.msg_id)

const msg = (task, n, extra = {}) => ({
  msg_id: `${task}-${n}`, task_id: task, ts: `2026-09-20T10:${String(n).padStart(2, '0')}:00Z`,
  from: 'HUM-4', kind: 'note', body: `${task} ${n}`, channel: 'lobby', parent_task_id: null, ...extra,
})

describe('activityOf / newestActivityFirst', () => {
  it('reads last_ts first, then received_at, then ts', () => {
    assert.equal(activityOf({ ts: 'a', received_at: 'b', last_ts: 'c' }), 'c')
    assert.equal(activityOf({ ts: 'a', received_at: 'b' }), 'b')
    assert.equal(activityOf({ ts: 'a' }), 'a')
    assert.equal(activityOf(null), '')
  })

  it('orders newest activity first and breaks ties by msg_id, stably', () => {
    const rows = [
      { msg_id: 'a', ts: '2026-09-20T10:00:00Z', last_ts: '2026-09-20T12:00:00Z' },
      { msg_id: 'b', ts: '2026-09-20T11:00:00Z' },
      { msg_id: 'c', ts: '2026-09-20T11:00:00Z' },
    ]
    assert.deepEqual(ids(newestActivityFirst(rows)), ['a', 'c', 'b'])
    assert.deepEqual(ids(newestActivityFirst(rows)), ids(newestActivityFirst(newestActivityFirst(rows))))
  })
})

describe('threadCards: one card per task, carrying the thread LAST activity', () => {
  it('keeps the root as the card and lifts the newest reply onto last_ts', () => {
    const cards = threadCards([msg('t1', 1), msg('t1', 9), msg('t2', 5)])
    assert.deepEqual(ids(cards), ['t1-1', 't2-5'])
    assert.equal(cards[0].last_ts, '2026-09-20T10:09:00Z')
    assert.equal(cards[0].count, 1)
    assert.equal(cards[1].last_ts, '2026-09-20T10:05:00Z')
  })

  it('a hub thread row keeps its own count (the hub already counted it)', () => {
    const row = feedRow({ task_id: 't3', first_ts: '2026-09-20T09:00:00Z', last_ts: '2026-09-20T09:30:00Z', count: 7, participants: ['HUM-4@box-wui'] })
    const cards = threadCards([row])
    assert.equal(cards[0].count, 6, 'feedRow already turned count into replies')
    assert.equal(cards[0].last_ts, '2026-09-20T09:30:00Z')
  })
})

describe('channelView: /channel and /dm order by last activity', () => {
  it('the busiest thread is on top even when it was started first', () => {
    /* t1 started 10:01 and was replied to at 10:20; t2 started 10:10 and went
       quiet. Ordering on the ROOT ts (the pre-CLE-3425 behaviour) put t2 first. */
    const rows = [msg('t1', 1), msg('t2', 10), msg('t1', 20)]
    assert.deepEqual(ids(channelView(rows).rows), ['t1-1', 't2-10'])
  })

  it('a live reply moves its card up with no refetch and adds no second card', () => {
    const before = [msg('t1', 1), msg('t2', 10)]
    assert.deepEqual(ids(channelView(before).rows), ['t2-10', 't1-1'])
    const after = mergeLive(before, msg('t1', 30))
    const v = channelView(after)
    assert.deepEqual(ids(v.rows), ['t1-1', 't2-10'])
    assert.equal(v.rows.length, 2, 'the card moved, it was not duplicated')
  })

  it('a live root still lands on top (CLE-3412 must not regress)', () => {
    const v = channelView(mergeLive([msg('t1', 1), msg('t2', 2)], msg('t9', 40)))
    assert.deepEqual(ids(v.rows), ['t9-40', 't2-2', 't1-1'])
  })
})

describe('orderChannels: the sidebar channel list, newest first', () => {
  const rows = [
    { channel_id: 'alerts', last_ts: null },
    { channel_id: 'live-proof', last_ts: '2026-09-20T03:24:56Z' },
    { channel_id: 'lobby', last_ts: '2026-09-20T03:04:50Z' },
    { channel_id: 'tasks', last_ts: null },
  ]

  it('orders by last activity, idle channels in a stable a-z tail', () => {
    /* exactly the four dev t1 rows measured before the fix, where the WUI
       rendered alerts, live-proof, lobby, tasks (the hub's a-z order) */
    assert.deepEqual(orderChannels(rows).map((c) => c.channel_id), ['live-proof', 'lobby', 'alerts', 'tasks'])
  })

  it('a live message re-orders the list with no refetch', () => {
    const at = { alerts: '2026-09-20T04:00:00Z' }
    assert.deepEqual(orderChannels(rows, at).map((c) => c.channel_id), ['alerts', 'live-proof', 'lobby', 'tasks'])
  })

  it('a channel created seconds ago tops the list although it is empty', () => {
    const fresh = { channel_id: 'brand-new', last_ts: null, created_at: '2026-09-20T05:00:00Z' }
    assert.deepEqual(orderChannels([...rows, fresh]).map((c) => c.channel_id)[0], 'brand-new')
    assert.equal(channelActivity(fresh), '2026-09-20T05:00:00Z')
  })

  it('never mutates its input', () => {
    const copy = rows.map((r) => ({ ...r }))
    orderChannels(rows)
    assert.deepEqual(rows, copy)
  })
})

describe('orderPeers / dmActivity: the sidebar DM list, newest first', () => {
  const peers = [
    { id: 'EZA-1', box: 'box-e2e-a', label: 'EZA-1@box-e2e-a', online: false },
    { id: 'EZB-1', box: 'box-e2e-b', label: 'EZB-1@box-e2e-b', online: false },
    { id: 'ORC-1', box: 'box-live-probe', label: 'ORC-1@box-live-probe', online: true },
  ]

  it('a peer we just talked to comes first, before online-and-silent ones', () => {
    const at = { 'EZB-1@box-e2e-b': '2026-09-19T18:56:38Z' }
    assert.deepEqual(orderPeers(peers, at).map((p) => p.label),
      ['EZB-1@box-e2e-b', 'ORC-1@box-live-probe', 'EZA-1@box-e2e-a'])
  })

  it('with no DM at all the tail stays online-first then a-z (CONTROL)', () => {
    assert.deepEqual(orderPeers(peers).map((p) => p.label),
      ['ORC-1@box-live-probe', 'EZA-1@box-e2e-a', 'EZB-1@box-e2e-b'])
  })

  it('dmActivity takes the newest moment per participant and drops our own label', () => {
    const at = dmActivity([
      { last_ts: '2026-09-19T18:56:38Z', participants: ['EZB-1@box-e2e-b', 'HUM-4@box-wui'] },
      { last_ts: '2026-09-19T17:56:38Z', participants: ['EZB-1@box-e2e-b', 'HUM-4@box-wui'] },
      { first_ts: '2026-09-19T19:00:00Z', participants: ['EZA-1@box-e2e-a', 'HUM-4@box-wui'] },
    ], 'HUM-4@box-wui')
    assert.deepEqual(at, { 'EZB-1@box-e2e-b': '2026-09-19T18:56:38Z', 'EZA-1@box-e2e-a': '2026-09-19T19:00:00Z' })
  })
})

describe('DOM contract: every list row carries the clock it is ordered by', () => {
  it('a message / thread card prints its ACTIVITY time, not the root ts', () => {
    const s = read('components/MessageCard.vue')
    assert.match(s, /:data-ts="at \|\| undefined"/)
    assert.match(s, /activityOf\(props\.msg\)/)
    assert.match(s, /formatTs\(at\.value/)
  })

  it('the thread list row carries last_ts', () => {
    assert.match(read('pages/index.vue'), /:data-ts="t\.last_ts \|\| undefined"/)
  })
})
