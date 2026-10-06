import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { REFUSED_PROBE_AFTER, backoffMs, cleanAs, createLiveClient, frameCursor, messageFromFrame, reconnectDelayMs, tokenStale, wsUrl } from '../../src/utils/live-ws.mjs'

function fakeWs() {
  const sockets = []
  class FakeWS {
    constructor(url) {
      this.url = url
      this.sent = []
      sockets.push(this)
    }
    send(s) { this.sent.push(JSON.parse(s)) }
    close() { this.onclose && this.onclose() }
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
    fire: (i) => { const t = timers[i]; t.done = true; t.fn() },
    timers,
  }
}

describe('live-ws helpers', () => {
  it('builds ws(s) URLs from the tenant http(s) base', () => {
    assert.equal(wsUrl('http://t1.localhost:58080/'), 'ws://t1.localhost:58080/v1/wui/ws')
    assert.equal(wsUrl('https://acme.dev.example.com'), 'wss://acme.dev.example.com/v1/wui/ws')
    assert.throws(() => wsUrl('t1.localhost'))
  })

  it('backs off exponentially with a cap', () => {
    assert.equal(backoffMs(0), 500)
    assert.equal(backoffMs(3), 4000)
    assert.equal(backoffMs(20), 30000)
  })

  it('normalises envelope, msg and flat message frames', () => {
    const a = messageFromFrame({ type: 'message', cursor: 'c', env: { from_box: 'box-a', to_box: 'box-b', msg: { v: 1, msg_id: 'm', body: 'hi', sig: 's' } } })
    assert.deepEqual(a, { v: 1, msg_id: 'm', body: 'hi', from_box: 'box-a', to_box: 'box-b', channel: null, parent_task_id: null, cursor: 'c', files: [] })
    assert.equal(messageFromFrame({ type: 'message', msg: { msg_id: 'x' } }).msg_id, 'x')
    assert.equal(messageFromFrame({ type: 'message', msg_id: 'y', body: 'b' }).msg_id, 'y')
  })
})

describe('live-ws contract rules (003 wui-live-ws 0.1.0)', () => {
  it('hello.as only carries a v:1 agent id', () => {
    assert.equal(cleanAs('HUM-2'), 'HUM-2')
    assert.equal(cleanAs(' hum-7 '), 'HUM-7')
    assert.equal(cleanAs('AgentA'), '')
    assert.equal(cleanAs(''), '')
  })

  it('omits an invalid as so the hub assigns HUM-<n>', () => {
    const { FakeWS, sockets } = fakeWs()
    createLiveClient({ url: 'ws://x', as: 'AgentA', WebSocketImpl: FakeWS }).connect()
    sockets[0].open()
    assert.deepEqual(sockets[0].sent[0], { type: 'hello' })
  })

  it('treats a missing or near-expiry upload token as stale', () => {
    const now = Date.parse('2026-09-18T20:00:00Z')
    assert.equal(tokenStale('', now), true)
    assert.equal(tokenStale('2026-09-18T20:00:10Z', now), true)
    assert.equal(tokenStale('2026-09-18T20:04:00Z', now), false)
  })

  it('requestToken sends {type:token} and resolves on the token frame', async () => {
    const { FakeWS, sockets } = fakeWs()
    const got = []
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, onToken: (f) => got.push(f) })
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    const p = c.requestToken()
    assert.deepEqual(sockets[0].sent.at(-1), { type: 'token' })
    sockets[0].recv({ type: 'token', upload_token: 'u2', upload_token_expires_at: 'x' })
    assert.equal((await p).upload_token, 'u2')
    assert.equal(got.length, 1)
  })

  // CLE-77795: after a hub redeploy the socket sits on the drained revision, so
  // a token request over it would re-mint on the dead process. redialForToken
  // drops the socket, and the reconnect's welcome (on the live revision) carries
  // the fresh token.
  it('redialForToken drops the socket and resolves with the reconnect welcome token', async () => {
    const t = manualTimers()
    const { FakeWS, sockets } = fakeWs()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: t.setTimer, clearTimer: t.clearTimer, random: () => 1 })
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome', upload_token: 'u1', upload_token_expires_at: 'x' })
    const p = c.redialForToken()
    assert.equal(sockets.length, 1) // the reconnect is only scheduled, not dialled yet
    const reconnect = t.timers.findIndex((timer) => !timer.done && timer.ms !== 10000)
    t.fire(reconnect)
    assert.equal(sockets.length, 2) // redialled onto a new socket
    sockets[1].open(); sockets[1].recv({ type: 'welcome', upload_token: 'u2', upload_token_expires_at: 'y' })
    assert.equal((await p).upload_token, 'u2')
  })

  it('redialForToken rejects when the session is signed out', async () => {
    const t = manualTimers()
    const { FakeWS, sockets } = fakeWs()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: t.setTimer, clearTimer: t.clearTimer, isSignedOut: async () => true })
    c.connect()
    // never opened: two refused dials drive the signed-out probe
    sockets[0].close()
    const p = c.redialForToken()
    // exhaust refused dials so probeThenRetry runs and parks signed_out
    for (let i = 0; i < REFUSED_PROBE_AFTER + 1 && i < t.timers.length; i++) {
      const idx = t.timers.findIndex((timer) => !timer.done && timer.ms !== 10000)
      if (idx < 0) break
      t.fire(idx)
      if (sockets.length > 1) sockets.at(-1).close()
    }
    await assert.rejects(p, (e) => e.token === 'signed_out' || e.token === 'timeout')
  })
})

describe('live-ws client', () => {
  it('hello carries token and display name; welcome opens and flushes subscriptions', () => {
    const { FakeWS, sockets } = fakeWs()
    const states = []
    const c = createLiveClient({ url: 'ws://x/v1/wui/ws', token: 'tok', as: 'hum-2', WebSocketImpl: FakeWS, onState: (s) => states.push(s) })
    c.subscribe('lobby-id')
    c.connect()
    const s = sockets[0]
    s.open()
    assert.deepEqual(s.sent[0], { type: 'hello', token: 'tok', as: 'HUM-2' })
    s.recv({ type: 'welcome', as: 'HUM-2' })
    assert.equal(c.state, 'open')
    assert.deepEqual(s.sent[1], { type: 'subscribe', task_id: 'lobby-id' })
    assert.deepEqual(states, ['connecting', 'open'])
  })

  it('delivers message frames live', () => {
    const { FakeWS, sockets } = fakeWs()
    const got = []
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, onMessage: (m) => got.push(m) })
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    sockets[0].recv({ type: 'message', msg: { msg_id: 'm1', task_id: 'L', body: 'hello' } })
    assert.equal(got.length, 1)
    assert.equal(got[0].body, 'hello')
  })

  it('queues sends until welcome and resolves on ack', async () => {
    const { FakeWS, sockets } = fakeWs()
    const t = manualTimers()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: t.setTimer, clearTimer: t.clearTimer })
    c.connect()
    const p = c.send({ task_id: 'L', body: 'hi', files: [{ file_id: 'f' }] })
    sockets[0].open()
    assert.equal(sockets[0].sent.some((f) => f.type === 'send'), false)
    sockets[0].recv({ type: 'welcome' })
    const sent = sockets[0].sent.find((f) => f.type === 'send')
    assert.equal(sent.kind, 'note')
    assert.deepEqual(sent.files, [{ file_id: 'f' }])
    sockets[0].recv({ type: 'ack', msg_id: sent.msg_id })
    assert.equal((await p).msg_id, sent.msg_id)
  })

  it('rejects a send on its error frame', async () => {
    const { FakeWS, sockets } = fakeWs()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS })
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    const p = c.send({ task_id: 'L', body: 'x' })
    const sent = sockets[0].sent.find((f) => f.type === 'send')
    sockets[0].recv({ type: 'error', msg_id: sent.msg_id, error: 'bad_json', status: 400 })
    await assert.rejects(p, (e) => e.token === 'bad_json' && e.status === 400)
  })

  it('reconnects with backoff and re-subscribes; close() stops it', () => {
    const { FakeWS, sockets } = fakeWs()
    const t = manualTimers()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: t.setTimer, clearTimer: t.clearTimer, random: () => 1 })
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    c.subscribe('T1')
    sockets[0].close()
    assert.equal(c.state, 'reconnecting')
    assert.equal(t.timers[0].ms, 500)
    t.fire(0)
    sockets[1].open(); sockets[1].recv({ type: 'welcome' })
    assert.deepEqual(sockets[1].sent.filter((f) => f.type === 'subscribe'), [{ type: 'subscribe', task_id: 'T1' }])
    c.close()
    assert.equal(c.state, 'closed')
    assert.equal(sockets.length, 2)
  })
})

describe('live-ws A1: channels, presence, reconnect (wui-live-ws 0.3 §3.2, §4, §7)', () => {
  it('keeps the hub-envelope channel / parent_task_id of a message frame', () => {
    const m = messageFromFrame({ type: 'message', task_id: 'T', cursor: 'c1', env: { from_box: 'box-a', to_box: 'box-wui', channel: 'alerts', parent_task_id: 'P', msg: { v: 1, msg_id: 'm', task_id: 'T' }, sig: 's' } })
    assert.equal(m.channel, 'alerts')
    assert.equal(m.parent_task_id, 'P')
    assert.equal(messageFromFrame({ env: { channel: '', msg: {} } }).channel, null)
  })

  it('puts channel, parent_task_id and a caller msg_id on the send frame, only when set', async () => {
    const { FakeWS, sockets } = fakeWs()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS })
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    const pa = c.send({ task_id: 'T', body: 'x', channel: 'tasks', parent_task_id: 'P', msg_id: 'mid-1' })
    const pb = c.send({ task_id: 'T', body: 'y' })
    const [a, b] = sockets[0].sent.filter((f) => f.type === 'send')
    sockets[0].recv({ type: 'ack', msg_id: a.msg_id })
    sockets[0].recv({ type: 'ack', msg_id: b.msg_id })
    await Promise.all([pa, pb])
    assert.equal(a.channel, 'tasks')
    assert.equal(a.parent_task_id, 'P')
    assert.equal(a.msg_id, 'mid-1')
    assert.equal('channel' in b, false)
    assert.equal('parent_task_id' in b, false)
    assert.equal('is_parent' in b, false)
  })

  it('sends is_parent 0 and 1, and keeps 0', async () => {
    const { FakeWS, sockets } = fakeWs()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS })
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    const p0 = c.send({ task_id: 'T', body: 'reply', is_parent: 0 })
    const p1 = c.send({ task_id: 'T', body: 'root', is_parent: 1 })
    const [a, b] = sockets[0].sent.filter((f) => f.type === 'send')
    sockets[0].recv({ type: 'ack', msg_id: a.msg_id })
    sockets[0].recv({ type: 'ack', msg_id: b.msg_id })
    await Promise.all([p0, p1])
    assert.equal(a.is_parent, 0)
    assert.equal(b.is_parent, 1)
    const echoed = messageFromFrame({ type: 'message', task_id: 'T', is_parent: 0, env: { from_box: 'box-wui', to_box: 'box-wui', msg: { v: 1, msg_id: 'm', task_id: 'T' } } })
    assert.equal(echoed.is_parent, 0)
  })

  it('emits presence frames to onPresence', () => {
    const { FakeWS, sockets } = fakeWs()
    const got = []
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, onPresence: (f) => got.push(f) })
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    sockets[0].recv({ type: 'presence', peer: 'CLE-07@box-a', status: 'online' })
    sockets[0].recv({ type: 'presence', peer: 'HUM-1@box-wui', status: 'offline' })
    assert.deepEqual(got.map((f) => `${f.peer}:${f.status}`), ['CLE-07@box-a:online', 'HUM-1@box-wui:offline'])
  })

  it('signals onReconnected after a drop (not on the first welcome), after re-subscribing, with the last cursors', () => {
    const { FakeWS, sockets } = fakeWs()
    const t = manualTimers()
    const events = []
    const c = createLiveClient({
      url: 'ws://x', WebSocketImpl: FakeWS, setTimer: t.setTimer, clearTimer: t.clearTimer,
      onReconnected: (w, info) => events.push({ w, info, subsSent: sockets.at(-1).sent.filter((f) => f.type === 'subscribe').length }),
    })
    c.subscribe('T1')
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome', as: 'HUM-1' })
    assert.equal(events.length, 0)
    sockets[0].recv({ type: 'message', task_id: 'T1', cursor: 'c7', envelope: {}, env: { msg: { msg_id: 'm7', task_id: 'T1' } } })
    assert.equal(c.lastCursor('T1'), 'c7')
    sockets[0].close()
    t.fire(0)
    sockets[1].open(); sockets[1].recv({ type: 'welcome', as: 'HUM-1' })
    assert.equal(events.length, 1)
    assert.equal(events[0].w.as, 'HUM-1')
    assert.equal(events[0].subsSent, 1)
    assert.deepEqual(events[0].info.cursors, { T1: 'c7' })
  })
})

describe('live-ws H4: channel subscription (wui-live-ws 0.4 §3.1)', () => {
  it('subscribes a channel once, re-sends it after a reconnect, and unsubscribes', () => {
    const { FakeWS, sockets } = fakeWs()
    const t = manualTimers()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: t.setTimer, clearTimer: t.clearTimer })
    c.subscribeChannel('#Tasks')
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    c.subscribeChannel('tasks')
    assert.deepEqual(sockets[0].sent.filter((f) => f.type === 'subscribe'), [{ type: 'subscribe', channel: 'tasks' }])
    sockets[0].close(); t.fire(0)
    sockets[1].open(); sockets[1].recv({ type: 'welcome' })
    assert.deepEqual(sockets[1].sent.filter((f) => f.type === 'subscribe'), [{ type: 'subscribe', channel: 'tasks' }])
    c.unsubscribeChannel('tasks')
    c.unsubscribeChannel('tasks')
    assert.deepEqual(sockets[1].sent.filter((f) => f.type === 'unsubscribe'), [{ type: 'unsubscribe', channel: 'tasks' }])
  })

  it('a new root from a channel subscription keeps the frame channel and cursor', () => {
    const { FakeWS, sockets } = fakeWs()
    const got = []
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, onMessage: (m) => got.push(m) })
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    sockets[0].recv({ type: 'message', task_id: 'R', channel: 'lobby', cursor: 'cur-R', received_at: '2026-09-19T09:00:00.123456Z',
      env: { from_box: 'box-wui', to_box: 'box-wui', msg: { v: 1, msg_id: 'm1', task_id: 'R', body: 'new root' }, sig: '' } })
    assert.equal(got.length, 1)
    assert.equal(got[0].channel, 'lobby')
    assert.equal(got[0].cursor, 'cur-R')
    assert.equal(c.lastCursor('R'), 'cur-R')
    assert.equal(messageFromFrame({ channel: 'lobby', env: { channel: '', msg: {} } }).channel, 'lobby')
  })
})

describe('live-ws reconnect cost (CLE-35076, perf lane P3)', () => {
  const tick = () => new Promise((r) => setImmediate(r))

  it('reconnect waits are equal-jittered: half of the backoff fixed, half random', () => {
    assert.equal(reconnectDelayMs(0, () => 0), 250)
    assert.equal(reconnectDelayMs(0, () => 1), 500)
    assert.equal(reconnectDelayMs(3, () => 0.5), 3000)
    assert.equal(reconnectDelayMs(20, () => 0), 15000)
    assert.equal(reconnectDelayMs(20, () => 1), 30000)
  })

  it('100 tabs dropped by one deploy no longer redial in the same instant', () => {
    let seed = 7
    const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647)
    const first = Array.from({ length: 100 }, () => reconnectDelayMs(0, rnd))
    assert.ok(Math.min(...first) >= 250 && Math.max(...first) <= 500)
    assert.ok(new Set(first).size > 50, 'spread over the window, not one instant')
  })

  it('a dial that opened then dropped never probes the session (a deploy, not a sign-out)', async () => {
    const { FakeWS, sockets } = fakeWs()
    const t = manualTimers()
    let probes = 0
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: t.setTimer, clearTimer: t.clearTimer, isSignedOut: async () => { probes++; return true } })
    c.connect()
    for (let i = 0; i < 4; i++) {
      sockets[i].open(); sockets[i].recv({ type: 'welcome' }); sockets[i].close()
      await tick()
      t.fire(i)
    }
    assert.equal(probes, 0)
    assert.equal(sockets.length, 5)
  })

  it(`${REFUSED_PROBE_AFTER} refused dials in a row: a signed-out session parks the client, connect() resumes it`, async () => {
    const { FakeWS, sockets } = fakeWs()
    const t = manualTimers()
    const states = []
    let probes = 0
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: t.setTimer, clearTimer: t.clearTimer, onState: (s) => states.push(s), isSignedOut: async () => { probes++; return true } })
    c.connect()
    sockets[0].close() // refused #1: plain backoff, no probe
    await tick()
    assert.equal(probes, 0)
    assert.equal(t.timers.length, 1)
    t.fire(0)
    sockets[1].close() // refused #2: probe -> signed out -> parked, no timer
    await tick()
    assert.equal(probes, 1)
    assert.equal(c.state, 'signed_out')
    assert.equal(t.timers.length, 1)
    assert.equal(states.at(-1), 'signed_out')
    c.connect() // e.g. a page asks again after a sign-in
    assert.equal(sockets.length, 3)
    sockets[2].open(); sockets[2].recv({ type: 'welcome' })
    assert.equal(c.state, 'open')
  })

  it('refused dials while still signed in (hub down, probe error) keep the usual backoff', async () => {
    for (const answer of [async () => false, async () => { throw new Error('network') }]) {
      const { FakeWS, sockets } = fakeWs()
      const t = manualTimers()
      const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: t.setTimer, clearTimer: t.clearTimer, isSignedOut: answer })
      c.connect()
      sockets[0].close(); await tick(); t.fire(0)
      sockets[1].close(); await tick()
      assert.equal(c.state, 'reconnecting')
      assert.equal(t.timers.length, 2)
      t.fire(1)
      assert.equal(sockets.length, 3)
    }
  })

  it('close() while the probe is in flight stays closed', async () => {
    const { FakeWS, sockets } = fakeWs()
    const t = manualTimers()
    let release
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: t.setTimer, clearTimer: t.clearTimer, isSignedOut: () => new Promise((r) => { release = r }) })
    c.connect()
    sockets[0].close(); await tick(); t.fire(0)
    sockets[1].close(); await tick()
    c.close()
    release(false); await tick()
    assert.equal(c.state, 'closed')
    assert.equal(t.timers.length, 1)
  })
})

/* db-payload audit round 2, R2-3: the hub's trimmed `message` frame must give
   the stores the same message object as the full frame it replaced. */
describe('R2-3 trimmed message frame', () => {
  const T = '5d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a'
  const ID = '457221b3-c833-4912-9527-03e6f874c40a'
  const AT = '2026-10-02T19:18:07.165146Z'
  /* pinned from the hub's encCursor (wui_test.go TestWUIChannelSubscribeNewRoot ack) */
  const CURSOR = 'MjAyNi0xMC0wMlQxOToxODowNy4xNjUxNDZafDQ1NzIyMWIzLWM4MzMtNDkxMi05NTI3LTAzZTZmODc0YzQwYQ'
  const msg = { v: 1, msg_id: ID, from: 'HUM-1', to: 'ALL-0', kind: 'note', body: 'hi', ts: '2026-10-02T19:18:07Z' }

  it('rebuilds the cursor exactly as the hub encodes it', () => {
    assert.equal(frameCursor(AT, ID), CURSOR)
    assert.equal(frameCursor('', ID), undefined)
    assert.equal(frameCursor(AT, undefined), undefined)
  })

  it('a browser post: trimmed and full frames give the same object', () => {
    const full = { type: 'message', task_id: T, channel: 'general', cursor: CURSOR, received_at: AT, is_parent: 1,
      env: { from_box: 'box-wui', to_box: 'box-wui', channel: 'general', msg: { ...msg, task_id: T, files: [] }, sig: '' } }
    const trimmed = { type: 'message', task_id: T, channel: 'general', received_at: AT, is_parent: 1,
      env: { msg: { ...msg } } }
    assert.deepEqual(messageFromFrame(trimmed), messageFromFrame(full))
    assert.equal(messageFromFrame(trimmed).task_id, T)
    assert.equal(messageFromFrame(trimmed).cursor, CURSOR)
  })

  it('kept fields win: signed agent post, files, other boxes', () => {
    const files = [{ file_id: 'f', name: 'a' }]
    const f = { type: 'message', task_id: T, received_at: AT,
      env: { from_box: 'box-desk', channel: 'other', msg: { ...msg, task_id: 'old', files }, sig: 'c2ln' } }
    const m = messageFromFrame(f)
    assert.equal(m.from_box, 'box-desk')
    assert.equal(m.to_box, 'box-wui')
    assert.equal(m.channel, 'other')
    assert.equal(m.task_id, T) /* the frame's task_id wins (copyMoveFields), as with a full frame */
    assert.deepEqual(m.files, files)
    assert.equal('sig' in m, false)
  })

  it('only `message` frames are rebuilt; an edit keeps its own cursor', () => {
    const e = messageFromFrame({ type: 'message_edited', task_id: T, received_at: AT, env: { msg: { ...msg } } })
    assert.equal('cursor' in e, false)
    assert.equal('files' in e, false)
  })
})

/* r3 B06: JSON.parse yields null, a number or a string for a valid frame.
   handle() must ignore those; a null used to throw on `switch (f.type)`. */
describe('non-object frames (r3 B06)', () => {
  function open() {
    const { FakeWS, sockets } = fakeWs()
    const got = []
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, onMessage: (m) => got.push(m) })
    c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    return { c, sockets, got }
  }

  for (const [name, frame] of [['null', null], ['a number', 0], ['a string', 'not-a-frame']]) {
    it(`ignores ${name} and still delivers the next message`, () => {
      const { c, sockets, got } = open()
      sockets[0].recv(frame)
      sockets[0].recv({ type: 'message', msg: { msg_id: 'm1', task_id: 'L', body: 'after' } })
      assert.equal(c.state, 'open')
      assert.equal(got.length, 1)
      assert.equal(got[0].body, 'after')
    })
  }
})
