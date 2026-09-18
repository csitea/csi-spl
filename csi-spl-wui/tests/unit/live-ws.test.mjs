import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { backoffMs, cleanAs, createLiveClient, messageFromFrame, tokenStale, wsUrl } from '../../utils/live-ws.mjs'

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
    assert.deepEqual(a, { v: 1, msg_id: 'm', body: 'hi', from_box: 'box-a', to_box: 'box-b', cursor: 'c' })
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
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: t.setTimer, clearTimer: t.clearTimer })
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
