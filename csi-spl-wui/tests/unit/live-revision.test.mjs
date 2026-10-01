/**
 * Bug B (t1 #spool-hub-bugs 4ecb4b0d): messages reached the other person
 * minutes late, with an old send time. A hub deploy leaves every open browser
 * socket on the old Cloud Run revision (still ponging, for up to the 3600 s
 * request timeout) while a post stored by the new revision is pushed only to
 * the sockets the new revision holds. Measured on prd 2026-09-30..10-01: 26 of
 * 112 browser sockets outlived their revision, p50 636 s, p90 2662 s.
 *
 * These pin the client half of the fix: the socket re-dials as soon as the
 * revision serving new requests is not the one its welcome named, and a tab
 * that comes back (visible / online) cannot keep a dead socket that reads open.
 */
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { createLiveClient, watchLive } from '../../src/utils/live-ws.mjs'

function fakeWs() {
  const sockets = []
  class FakeWS {
    constructor(url) {
      this.url = url
      this.sent = []
      this.closed = false
      sockets.push(this)
    }
    send(s) { this.sent.push(JSON.parse(s)) }
    /* a half-open socket: close() never reports back */
    close() { this.closed = true }
    open() { this.onopen && this.onopen() }
    recv(obj) { this.onmessage && this.onmessage({ data: JSON.stringify(obj) }) }
  }
  return { FakeWS, sockets }
}

function manualTimers() {
  const timers = []
  return {
    setTimer: (fn, ms) => { const t = { fn, ms, done: false }; timers.push(t); return t },
    clearTimer: (t) => { if (t) t.done = true },
    fireLast: () => { const t = timers.at(-1); t.done = true; t.fn() },
    timers,
  }
}

function openClient({ live = 'rev-1', welcomeRev = 'rev-1', ...rest } = {}) {
  const { FakeWS, sockets } = fakeWs()
  const reconnected = []
  const tm = manualTimers()
  const state = { live }
  const c = createLiveClient({
    url: 'ws://x', WebSocketImpl: FakeWS, setTimer: tm.setTimer, clearTimer: tm.clearTimer,
    fetchRevision: async () => state.live,
    onReconnected: (w) => reconnected.push(w),
    ...rest,
  })
  c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome', revision: welcomeRev })
  c.subscribe('task-1')
  return { c, sockets, reconnected, tm, state }
}

describe('bug B: a socket left on a retired hub revision', () => {
  it('re-dials when the live revision is not the welcome revision, then catches up', async () => {
    const { c, sockets, reconnected, state } = openClient()
    assert.equal(await c.checkRevision(), false, 'same revision: nothing to do')
    assert.equal(sockets.length, 1)

    state.live = 'rev-2' /* a hub deploy: new requests go to rev-2, this socket stays on rev-1 */
    assert.equal(await c.checkRevision(), true)
    assert.equal(sockets[0].closed, true, 'the stale socket is dropped')
    assert.equal(sockets.length, 2, 'and a new one dialled at once, with no backoff wait')
    sockets[1].open(); sockets[1].recv({ type: 'welcome', revision: 'rev-2' })
    assert.deepEqual(sockets[1].sent.find((f) => f.type === 'subscribe'), { type: 'subscribe', task_id: 'task-1' })
    assert.equal(reconnected.length, 1, 'the catch-up read runs for what the old socket never pushed')
    assert.equal(await c.checkRevision(), false)
  })

  it('a late close from the dropped socket does not dial a second time', async () => {
    const { c, sockets, state } = openClient()
    state.live = 'rev-2'
    await c.checkRevision()
    sockets[0].onclose && sockets[0].onclose()
    assert.equal(sockets.length, 2)
  })

  it('a send pending on the stale socket fails closed (one idempotent resend follows)', async () => {
    const { c, state } = openClient()
    const p = c.send({ task_id: 't', body: 'hi', msg_id: 'm-1' })
    state.live = 'rev-2'
    await c.checkRevision()
    await assert.rejects(p, (e) => e.token === 'closed')
  })

  it('CONTROL: an unknown live revision, or a welcome without one (an old hub), never re-dials', async () => {
    const a = openClient({ live: '' })
    assert.equal(await a.c.checkRevision(), false)
    const b = openClient({ welcomeRev: null, live: 'rev-2' })
    assert.equal(await b.c.checkRevision(), false)
    const failing = openClient({ fetchRevision: async () => { throw new Error('offline') } })
    assert.equal(await failing.c.checkRevision(), false)
    assert.equal(a.sockets.length + b.sockets.length + failing.sockets.length, 3)
  })
})

describe('bug B: a tab that comes back cannot keep a dead socket', () => {
  it('wake() probes an open socket and re-dials one that answers nothing', () => {
    const { c, sockets, tm } = openClient()
    c.wake()
    assert.deepEqual(sockets[0].sent.at(-1), { type: 'token' })
    tm.fireLast() /* probeTimeoutMs passed, no frame */
    assert.equal(sockets[0].closed, true)
    assert.equal(sockets.length, 2)
  })

  it('CONTROL: a socket that answers the probe is kept', () => {
    const { c, sockets, tm } = openClient()
    c.wake()
    sockets[0].recv({ type: 'token', upload_token: 'u' })
    tm.fireLast()
    assert.equal(sockets.length, 1)
    assert.equal(sockets[0].closed, false)
  })

  it('wake() dials a reconnect that is waiting out its backoff now', () => {
    const { FakeWS, sockets } = fakeWs()
    const tm = manualTimers()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: tm.setTimer, clearTimer: tm.clearTimer })
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    sockets[0].onclose()
    assert.equal(c.state, 'reconnecting')
    assert.equal(sockets.length, 1)
    c.wake()
    assert.equal(sockets.length, 2)
  })

  it('watchLive checks on its timer and on visible, wakes on visible and online, and stops', () => {
    const calls = []
    const client = { checkRevision: async () => { calls.push('check') }, wake: () => calls.push('wake') }
    const listeners = {}
    const target = (name) => ({
      addEventListener: (ev, fn) => { listeners[`${name}:${ev}`] = fn },
      removeEventListener: (ev) => { delete listeners[`${name}:${ev}`] },
    })
    const doc = { ...target('doc'), visibilityState: 'visible' }
    let tick = null
    const stop = watchLive(client, { doc, win: target('win'), setEvery: (fn) => { tick = fn; return 1 }, clearEvery: () => { tick = null } })
    tick()
    listeners['doc:visibilitychange']()
    listeners['win:online']()
    assert.deepEqual(calls, ['check', 'wake', 'check', 'wake'])
    doc.visibilityState = 'hidden'
    listeners['doc:visibilitychange']()
    assert.equal(calls.length, 4, 'going hidden does nothing')
    stop()
    assert.equal(tick, null)
    assert.deepEqual(Object.keys(listeners), [])
  })
})
