// SPL-2149: the last copy of a feed and of the channel list, for offline
// reading (utils/offline-feed.mjs), and the offline predicates.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  MAX_CHARS, MAX_FEEDS, OFFLINE_FEEDS_KEY, clearOfflineFeeds, feedKey, keepPage, keptChannelRows, keptPage, showKept,
  loadChannels, loadFeed, readFailedOffline, saveChannels, saveFeed,
} from '../../src/utils/offline-feed.mjs'
import { offlineError, readsKeptCopy } from '../../src/utils/offline-queue.mjs'

function memStore(limit = Infinity) {
  const m = new Map()
  return {
    m,
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => {
      if (String(v).length > limit) throw new Error('QuotaExceededError')
      m.set(k, String(v))
    },
    removeItem: (k) => { m.delete(k) },
  }
}
const row = (id, body = 'hi') => ({ msg_id: id, task_id: 't-' + id, body, ts: '2026-10-20T10:00:00Z' })
const clock = (start) => { let t = start; return () => (t += 1000) }

describe('offline-feed (SPL-2149)', () => {
  it('keys a feed by tenant and channel or DM peer; no feed, no key', () => {
    assert.equal(feedKey('t1', { channel: 'lobby' }), 't1|ch:lobby')
    assert.equal(feedKey('t1', { peer: 'CLE-11' }), 't1|dm:CLE-11')
    assert.equal(feedKey('', { channel: 'lobby' }), '-|ch:lobby')
    assert.equal(feedKey('t1', {}), '')
  })

  it('a saved page comes back with the time it was read; another feed has none', () => {
    const store = memStore()
    const now = () => Date.parse('2026-10-20T10:05:00Z')
    assert.equal(saveFeed('t1|ch:lobby', { messages: [row('a'), row('b')], totals: { 't-a': { count: 2, last_ts: 'x' } } }, { store, now }), true)
    const kept = loadFeed('t1|ch:lobby', { store })
    assert.deepEqual(kept.messages.map((m) => m.msg_id), ['a', 'b'])
    assert.equal(kept.at, '2026-10-20T10:05:00.000Z')
    assert.deepEqual(kept.totals, { 't-a': { count: 2, last_ts: 'x' } })
    assert.equal(loadFeed('t1|ch:alerts', { store }), null)
    assert.equal(loadFeed('', { store }), null)
  })

  it(`keeps at most ${MAX_FEEDS} feeds, the one read longest ago dropped first`, () => {
    const store = memStore()
    const now = clock(Date.parse('2026-10-20T10:00:00Z'))
    for (let i = 0; i <= MAX_FEEDS; i++) saveFeed(`t1|ch:c${i}`, { messages: [row(String(i))] }, { store, now })
    assert.equal(loadFeed('t1|ch:c0', { store }), null)
    assert.ok(loadFeed(`t1|ch:c${MAX_FEEDS}`, { store }))
    assert.equal(Object.keys(JSON.parse(store.getItem(OFFLINE_FEEDS_KEY)).feeds).length, MAX_FEEDS)
  })

  it('a store that refuses the size drops the oldest feeds until it fits', () => {
    const store = memStore(2500)
    const now = clock(Date.parse('2026-10-20T10:00:00Z'))
    const big = 'x'.repeat(900)
    saveFeed('t1|ch:a', { messages: [row('a', big)] }, { store, now })
    saveFeed('t1|ch:b', { messages: [row('b', big)] }, { store, now })
    saveFeed('t1|ch:c', { messages: [row('c', big)] }, { store, now })
    assert.equal(loadFeed('t1|ch:a', { store }), null, 'oldest went')
    assert.ok(loadFeed('t1|ch:c', { store }), 'newest kept')
    assert.ok(MAX_CHARS > 1_000_000)
  })

  it('a page bigger than the store can hold is not kept and never throws', () => {
    const store = memStore(100)
    assert.equal(saveFeed('t1|ch:a', { messages: [row('a', 'y'.repeat(500))] }, { store }), false)
    assert.equal(loadFeed('t1|ch:a', { store }), null)
  })

  it('the channel list per tenant; sign-out drops feeds and lists in one call', () => {
    const store = memStore()
    saveChannels('t1', [{ channel_id: 'lobby' }], { store })
    saveFeed('t1|ch:lobby', { messages: [row('a')] }, { store })
    assert.deepEqual(loadChannels('t1', { store }).rows, [{ channel_id: 'lobby' }])
    assert.equal(loadChannels('t2', { store }), null)
    clearOfflineFeeds(store)
    assert.equal(store.getItem(OFFLINE_FEEDS_KEY), null)
    assert.equal(loadFeed('t1|ch:lobby', { store }), null)
    assert.equal(loadChannels('t1', { store }), null)
  })

  it('broken stored JSON reads as nothing kept', () => {
    const store = memStore()
    store.setItem(OFFLINE_FEEDS_KEY, '{nope')
    assert.equal(loadFeed('t1|ch:a', { store }), null)
    assert.equal(saveFeed('t1|ch:a', { messages: [] }, { store }), true)
  })

  it('a read failed offline: browser offline, a fetch that reached no server, the offline token', () => {
    const online = { onLine: true }
    assert.equal(readFailedOffline(new Error('x'), { onLine: false }), true)
    assert.equal(readFailedOffline(new TypeError('Failed to fetch'), online), true)
    assert.equal(readFailedOffline(new TypeError('NetworkError when attempting to fetch resource.'), online), true)
    assert.equal(readFailedOffline(new TypeError('Load failed'), online), true)
    assert.equal(readFailedOffline(offlineError(), online), true)
  })

  it('CONTROL: a hub answer or a bug is not "offline" (the error shows, no stale copy)', () => {
    const online = { onLine: true }
    assert.equal(readFailedOffline(Object.assign(new Error('forbidden'), { status: 403 }), online), false)
    assert.equal(readFailedOffline(new TypeError("Cannot read properties of undefined (reading 'x')"), online), false)
    assert.equal(readFailedOffline(null, online), false)
  })

  it('readsKeptCopy: only an unanswered probe (unknown) while the browser is offline', () => {
    assert.equal(readsKeptCopy('unknown', { onLine: false }), true)
    assert.equal(readsKeptCopy('unknown', { onLine: true }), false)
    assert.equal(readsKeptCopy('out', { onLine: false }), false)
    assert.equal(readsKeptCopy('in', { onLine: false }), false)
    assert.equal(readsKeptCopy('unknown', null), false)
  })

  it('the store calls: a kept page and channel rows come back only when the read failed offline', () => {
    const store = memStore()
    const now = () => Date.parse('2026-10-20T10:05:00Z')
    assert.equal(keepPage('t1', { channel: 'lobby' }, { messages: [row('a')] }, { store, now }), true)
    saveChannels('t1', [{ id: 'lobby' }], { store, now })
    const offline = { store, nav: { onLine: false } }
    const online = { store, nav: { onLine: true } }
    assert.deepEqual(keptPage('t1', offlineError(), { channel: 'lobby' }, offline).messages.map((m) => m.msg_id), ['a'])
    assert.deepEqual(keptChannelRows('t1', offlineError(), offline), [{ id: 'lobby' }])
    /* CONTROL: a hub answer reads nothing back; a never-read feed has no copy */
    const denied = Object.assign(new Error('forbidden'), { status: 403 })
    assert.equal(keptPage('t1', denied, { channel: 'lobby' }, online), null)
    assert.equal(keptChannelRows('t1', denied, online), null)
    assert.equal(keptPage('t1', offlineError(), { channel: 'general' }, offline), null)
    assert.equal(keptChannelRows('t2', offlineError(), offline), null)
  })

  it('showKept: the open feed\'s kept copy offline; CONTROL: never another feed\'s rows or time', () => {
    const store = memStore()
    keepPage('t1', { channel: 'lobby' }, { messages: [row('a')], totals: { x: 1 } }, { store, now: () => Date.parse('2026-10-20T10:05:00Z') })
    const ref = (v) => ({ value: v })
    const state = (channel) => ({
      api: { tenant: 't1' }, active: ref(channel), peer: ref(''), messages: ref([row('old')]),
      totals: ref({}), olderCursor: ref('c1'), offlineAt: ref(null),
    })
    const held = (rows) => [...rows, row('held')]
    const opts = { store, nav: { onLine: false } }
    const s = state('lobby')
    assert.equal(showKept(s, held, offlineError(), { channel: 'lobby' }, opts), true)
    assert.deepEqual(s.messages.value.map((m) => m.msg_id), ['a', 'held'])
    assert.equal(s.offlineAt.value, '2026-10-20T10:05:00.000Z')
    assert.equal(s.olderCursor.value, null)
    const never = state('general')
    never.offlineAt.value = 'stale'
    assert.equal(showKept(never, held, offlineError(), { channel: 'general' }, opts), false)
    assert.deepEqual(never.messages.value.map((m) => m.msg_id), ['held'])
    assert.equal(never.offlineAt.value, null)
    /* the user moved on before the read failed: nothing is written */
    const moved = state('general')
    assert.equal(showKept(moved, held, offlineError(), { channel: 'lobby' }, opts), false)
    assert.deepEqual(moved.messages.value.map((m) => m.msg_id), ['old'])
  })
})
