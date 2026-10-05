/**
 * Spec 066 lane L6: the measurement points. perf-mark.mjs pairs the starts
 * and ends that MessageComposer, LiveFeed and live-ws.mjs report; the
 * collector (perf-rum.mjs) owns the hub clock for M4. Each pairing is pinned
 * here with its control: the same input minus the start (or the end) gives
 * no sample.
 */
import { afterEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  perfAttach, perfDelivered, perfFeed, perfFeedState, perfKeydown, perfMark, perfMarkReset,
  perfNavStart, perfSendStart,
} from '../../src/utils/perf-mark.mjs'
import { createPerfCollector, PERF_CLOCK_ERR_MAX_MS, perfFeedPair, perfViewKind } from '../../src/utils/perf-rum.mjs'
import { awayBucket, createLiveClient, watchLive } from '../../src/utils/live-ws.mjs'

/* afterPaint without a browser is a setTimeout 0 */
const painted = () => new Promise((r) => setTimeout(r, 5))

function capture() {
  const got = []
  const sink = { mark: (metric, valueMs, fields) => { got.push({ metric, valueMs, ...(fields || {}) }); return true }, deliver: (hub, wall) => { got.push({ metric: 'deliver', hub, wall }) }, feed: perfFeedPair }
  return { got, sink }
}

const own = (m) => m.from === 'HUM-1'
const row = (id, extra = {}) => ({ msg_id: id, from: 'HUM-1', ...extra })

afterEach(() => perfMarkReset())

describe('the queue before the collector loads', () => {
  it('RUM off: nothing is queued, the collector gets nothing on attach', () => {
    perfMarkReset({ on: false })
    assert.equal(perfMark('send_ack', 10), false)
    const { got, sink } = capture()
    perfAttach(sink)
    assert.deepEqual(got, [])
  })
  it('RUM on: early marks wait (at most 32) and reach the collector on attach', () => {
    perfMarkReset({ on: true })
    for (let i = 0; i < 40; i++) perfMark('load_rail', i)
    const { got, sink } = capture()
    perfAttach(sink)
    assert.equal(got.length, 32)
    assert.equal(got[0].valueMs, 0)
    assert.equal(perfMark('send_ack', 5), true)
  })
  it('a throwing sink never throws into the caller', () => {
    perfAttach({ mark: () => { throw new Error('boom') } })
    assert.doesNotThrow(() => perfMark('send_ack', 1))
    assert.equal(perfMark('send_ack', 1), false)
  })
})

describe('M2 load_messages and M5 switch_view (LiveFeed)', () => {
  it('the first view of the load marks load_messages once, when its rows show', async () => {
    const { got, sink } = capture()
    perfAttach(sink)
    const f = perfFeedState()
    perfFeed(f, { rows: [], loading: true, key: 'p|/channel/a', own })
    perfFeed(f, { rows: [row('1')], loading: false, key: 'p|/channel/a', own })
    perfFeed(f, { rows: [row('1'), row('2')], loading: false, key: 'p|/channel/a', own })
    await painted()
    assert.deepEqual(got.map((s) => s.metric), ['load_messages'])
  })
  it('CONTROL: an empty feed before any loading is not "shown"', async () => {
    const { got, sink } = capture()
    perfAttach(sink)
    perfFeed(perfFeedState(), { rows: [], loading: false, key: 'p|/channel/a', own })
    await painted()
    assert.deepEqual(got, [])
  })
  it('a key change times the switch from the navigation start, with the view kind', async () => {
    const { got, sink } = capture()
    perfAttach(sink)
    const f = perfFeedState()
    perfFeed(f, { rows: [row('1')], loading: false, key: 'p|/channel/a', own })
    perfNavStart()
    perfFeed(f, { rows: [], loading: true, key: 'p|/dm/x', path: '/dm/x', own })
    perfFeed(f, { rows: [], loading: false, key: 'p|/dm/x', path: '/dm/x', own })
    await painted()
    const sw = got.filter((s) => s.metric === 'switch_view')
    assert.equal(sw.length, 1)
    assert.equal(sw[0].view, 'dm')
    assert.ok(sw[0].valueMs >= 0)
  })
  it('a feed born of a navigation (another page) times the switch; one born with the load does not', async () => {
    const { got, sink } = capture()
    perfAttach(sink)
    perfFeed(perfFeedState(), { rows: [row('1')], loading: false, key: 'p|/channel/a', own })
    perfNavStart()
    perfFeed(perfFeedState(), { rows: [row('2')], loading: false, key: 'p|/lobby', path: '/lobby', own })
    await painted()
    assert.deepEqual(got.map((s) => [s.metric, s.view]), [['load_messages', undefined], ['switch_view', 'channel']])
  })
  it('a navigation before any feed showed rows means no load_messages (not a landing view), it is a switch', async () => {
    const { got, sink } = capture()
    perfAttach(sink)
    perfNavStart()
    perfFeed(perfFeedState(), { rows: [row('1')], loading: false, key: 'p|/channel/a', own })
    await painted()
    assert.deepEqual(got.map((s) => s.metric), ['switch_view'])
  })
  it('one navigation that changes two feeds is timed once, by the feed that shows rows', async () => {
    const { got, sink } = capture()
    perfAttach(sink)
    const side = perfFeedState()
    perfFeed(side, { rows: [row('t1')], loading: false, key: 't|x', own })
    await painted()
    got.length = 0
    perfNavStart()
    perfFeed(side, { rows: [], loading: false, key: 't|', thread: true, own })
    const page = perfFeedState()
    perfFeed(page, { rows: [row('2')], loading: false, key: 'p|/lobby', path: '/lobby', own })
    perfFeed(side, { rows: [row('t2')], loading: false, key: 't|', thread: true, own })
    await painted()
    assert.deepEqual(got.map((s) => [s.metric, s.view]), [['switch_view', 'channel']])
  })
  it('view kinds carry no id', () => {
    assert.equal(perfViewKind('/channel/secret-name'), 'channel')
    assert.equal(perfViewKind('/dm/HUM-3'), 'dm')
    assert.equal(perfViewKind('/t/abc'), 'topic')
    assert.equal(perfViewKind('/channel/x', true), 'topic')
    assert.equal(perfViewKind('/search'), 'search')
    assert.equal(perfViewKind('/issues'), undefined)
  })
})

describe('M3 send_ack (composer start, LiveFeed end)', () => {
  function landed() {
    const { got, sink } = capture()
    perfAttach(sink)
    const f = perfFeedState()
    perfFeed(f, { rows: [row('old')], loading: false, key: 'k', own })
    got.length = 0
    return { got, f }
  }
  it('a pending row that loses pending is one ok sample', async () => {
    const { got, f } = landed()
    perfSendStart()
    perfFeed(f, { rows: [row('old'), row('n', { pending: true })], loading: false, key: 'k', own })
    perfFeed(f, { rows: [row('old'), row('n')], loading: false, key: 'k', own })
    await painted()
    const s = got.filter((x) => x.metric === 'send_ack')
    assert.equal(s.length, 1)
    assert.equal(s[0].outcome, undefined)
  })
  it('a pending row that vanishes is a fail sample', async () => {
    const { got, f } = landed()
    perfSendStart()
    perfFeed(f, { rows: [row('old'), row('n', { pending: true })], loading: false, key: 'k', own })
    perfFeed(f, { rows: [row('old')], loading: false, key: 'k', own })
    await painted()
    assert.deepEqual(got.filter((x) => x.metric === 'send_ack').map((x) => x.outcome), ['fail'])
  })
  it('a row that arrives already confirmed (the mock) pairs with the send start', async () => {
    const { got, f } = landed()
    perfSendStart()
    perfFeed(f, { rows: [row('old'), row('n')], loading: false, key: 'k', own })
    await painted()
    assert.equal(got.filter((x) => x.metric === 'send_ack').length, 1)
  })
  it('CONTROL: no send start, or someone else\'s row, gives no sample', async () => {
    const { got, f } = landed()
    perfFeed(f, { rows: [row('old'), row('n')], loading: false, key: 'k', own })
    perfSendStart()
    perfFeed(f, { rows: [row('old'), row('n'), row('o', { from: 'HUM-9' })], loading: false, key: 'k', own })
    await painted()
    assert.equal(got.filter((x) => x.metric === 'send_ack').length, 0)
  })
  it('two feeds showing the same row report it once', async () => {
    const { got, f } = landed()
    const g = perfFeedState()
    perfFeed(g, { rows: [row('old')], loading: false, key: 'k2', own })
    perfSendStart()
    for (const x of [f, g]) perfFeed(x, { rows: [row('old'), row('n', { pending: true })], loading: false, key: x === f ? 'k' : 'k2', own })
    for (const x of [f, g]) perfFeed(x, { rows: [row('old'), row('n')], loading: false, key: x === f ? 'k' : 'k2', own })
    await painted()
    assert.equal(got.filter((x) => x.metric === 'send_ack').length, 1)
  })
})

describe('M6 type_next_paint', () => {
  it('one keydown in ten, the first included', async () => {
    const { got, sink } = capture()
    perfAttach(sink)
    for (let i = 0; i < 21; i++) perfKeydown(0)
    await painted()
    assert.equal(got.filter((x) => x.metric === 'type_next_paint').length, 3)
  })
})

describe('M4 deliver_visible (hub clock in the collector)', () => {
  function withClock(errMs) {
    const t = { now: 0 }
    const res = { ok: true, status: 202, json: async () => ({ hub_ms: 10_000 }) }
    const c = createPerfCollector({
      send: () => { t.now += errMs * 2; return Promise.resolve(res) },
      sessionId: '00000000-0000-4000-8000-000000000000', ready: () => true,
      wallNow: () => 5_000 + t.now, setTimer: () => 0, clearTimer: () => {}, idle: (fn) => fn(),
    })
    return c
  }
  const settle = () => new Promise((r) => setTimeout(r, 0))
  it('no clock yet: dropped and counted', () => {
    const c = withClock(10)
    assert.equal(c.deliver(1000, 2000), false)
    assert.equal(c.state().clockDropped, 1)
  })
  it('with a clock: hub accept -> painted on the hub clock, error stored', async () => {
    const c = withClock(10)
    c.mark('send_ack', 1)
    await c.flush(); await settle(); await settle()
    const clock = c.clock()
    assert.equal(clock.errMs, 10)
    assert.equal(c.deliver(9_000, 5_000), true)
    assert.equal(c.state().buffered, 1)
  })
  it(`CONTROL: an offset error over ${PERF_CLOCK_ERR_MAX_MS} ms drops the sample`, async () => {
    const c = withClock(PERF_CLOCK_ERR_MAX_MS + 1)
    c.mark('send_ack', 1)
    await c.flush(); await settle(); await settle()
    assert.equal(c.deliver(9_000, 5_000), false)
    assert.equal(c.state().clockDropped, 1)
  })
  it('perfDelivered hands each live row to the collector once, never a pending one', async () => {
    const { got, sink } = capture()
    perfAttach(sink)
    const m = { msg_id: 'x', received_at: '2026-10-03T10:00:00Z' }
    perfDelivered(m)
    perfDelivered(m)
    perfDelivered({ msg_id: 'y', pending: true, received_at: '2026-10-03T10:00:00Z' })
    await painted()
    assert.equal(got.length, 1)
    assert.equal(got[0].hub, Date.parse('2026-10-03T10:00:00Z'))
  })
  it('perfDelivered pairs the hub time with the injected wall clock', async () => {
    const { got, sink } = capture()
    perfAttach(sink)
    const hub = Date.parse('2026-10-03T10:00:00Z')
    perfDelivered({ msg_id: 'z', received_at: '2026-10-03T10:00:00Z' }, { wallNow: () => hub + 250 })
    await painted()
    assert.deepEqual(got, [{ metric: 'deliver', hub, wall: hub + 250 }])
  })
})

describe('M8 reconnect_live (live-ws.mjs)', () => {
  function client(t) {
    const sockets = []
    class FakeWS {
      constructor() { sockets.push(this); this.sent = [] }
      send(s) { this.sent.push(JSON.parse(s)) }
      close() { this.closed = true }
    }
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: () => ({}), clearTimer: () => {}, now: () => t.now })
    c.connect(); sockets[0].onopen(); sockets[0].onmessage({ data: '{"type":"welcome"}' })
    return { c, sockets }
  }
  const reopen = (sockets) => { const s = sockets.at(-1); s.onopen(); s.onmessage({ data: '{"type":"welcome"}' }) }
  it('away > 30 s, socket dropped: wake -> reconnected is one sample with its bucket', async () => {
    const { got, sink } = capture()
    perfAttach(sink)
    const t = { now: 0 }
    const { c, sockets } = client(t)
    sockets[0].onclose()
    c.wake(400_000)
    t.now = 700
    reopen(sockets)
    await painted()
    assert.deepEqual(got, [{ metric: 'reconnect_live', valueMs: 700, hiddenS: '300-3600' }])
  })
  it('CONTROL: a short away, or no wake, times nothing', async () => {
    const { got, sink } = capture()
    perfAttach(sink)
    const t = { now: 0 }
    const { c, sockets } = client(t)
    sockets[0].onclose()
    c.wake(10_000)
    reopen(sockets)
    sockets.at(-1).onclose()
    c.connect()
    reopen(sockets)
    await painted()
    assert.deepEqual(got, [])
  })
  it('watchLive passes the away time of a hidden tab to wake()', () => {
    const t = { now: 0 }
    const woke = []
    const l = {}
    const doc = { visibilityState: 'visible', addEventListener: (e, fn) => { l[e] = fn }, removeEventListener: () => {} }
    const win = { addEventListener: (e, fn) => { l[e] = fn }, removeEventListener: () => {} }
    watchLive({ checkRevision: async () => {}, wake: (ms) => woke.push(ms) }, { doc, win, setEvery: () => 0, clearEvery: () => {}, now: () => t.now })
    doc.visibilityState = 'hidden'; l.visibilitychange()
    t.now = 45_000
    doc.visibilityState = 'visible'; l.visibilitychange()
    l.offline(); t.now = 46_000; l.online()
    assert.deepEqual(woke, [45_000, 1_000])
  })
  it('buckets', () => {
    assert.equal(awayBucket(31_000), '30-300')
    assert.equal(awayBucket(300_000), '300-3600')
    assert.equal(awayBucket(3_600_000), '3600+')
  })
})
