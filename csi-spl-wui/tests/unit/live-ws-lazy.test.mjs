// SPL-6342: the hub socket's code (live-ws.mjs) is out of the entry chunk.
// useLive dials through lazyLiveClient (live-ws-lazy.mjs), which loads it with
// the first call and replays every call made before, in order, on the real
// client. These tests drive the real live-ws with a fake socket, through the
// lazy client, and check the real client saw what an eager one would have.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import * as liveWs from '../../src/utils/live-ws.mjs'
import { lazyLiveClient } from '../../src/utils/live-ws-lazy.mjs'

const read = (rel) => readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8')
const bare = (name) => new RegExp(`(?<![.\\w'])${name}\\b`)

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

/** A load the test releases by hand, so a call can land before the module. */
function heldLoad(mod = liveWs) {
  let release
  const gate = new Promise((r) => { release = r })
  let calls = 0
  return {
    load: () => { calls++; return gate.then(() => mod) },
    release: () => release(),
    calls: () => calls,
  }
}

const tick = () => new Promise((r) => setTimeout(r, 0))

describe('lazyLiveClient: calls before the load (SPL-6342)', () => {
  it('replays connect and the follows in order on the real client, and the socket gets them after welcome', async () => {
    const { FakeWS, sockets } = fakeWs()
    const states = []
    const held = heldLoad()
    const c = lazyLiveClient({ url: 'ws://h/v1/wui/ws', WebSocketImpl: FakeWS, onState: (s) => states.push(s) }, { load: held.load })
    c.subscribeAll()
    c.connect()
    c.subscribeChannel('#Ops')
    c.subscribe('t-1')
    c.subscribePeer('HUM-2')
    c.unsubscribe('t-1')
    assert.equal(sockets.length, 0, 'no socket before the module is there')
    assert.equal(c.state, 'connecting', 'connect is seen at once')
    assert.deepEqual(states, ['connecting'])
    assert.equal(c.welcome, null)
    assert.equal(c.lastCursor('t-1'), '')

    held.release()
    await tick()
    assert.equal(held.calls(), 1, 'one load for every call')
    assert.equal(sockets.length, 1, 'the replayed connect dialled once')
    sockets[0].open()
    sockets[0].recv({ type: 'welcome', as: 'HUM-1' })
    const subs = sockets[0].sent.filter((f) => f.type === 'subscribe')
    assert.equal(subs.length, 3, `three follows reach the socket: ${JSON.stringify(subs)}`)
    assert.ok(subs.some((f) => f.all === true), 'subscribeAll replayed')
    assert.ok(subs.some((f) => f.channel === 'ops'), 'subscribeChannel replayed')
    assert.ok(subs.some((f) => f.peer === 'HUM-2'), 'subscribePeer replayed')
    assert.ok(!subs.some((f) => f.task_id === 't-1'), 'unsubscribe replayed after subscribe: t-1 is not followed')
    assert.equal(c.state, 'open', 'after the load the state is the real client\'s')
    assert.equal(c.welcome.as, 'HUM-1')
  })

  it('a send before the load waits for it and resolves with the ack', async () => {
    const { FakeWS, sockets } = fakeWs()
    const held = heldLoad()
    const c = lazyLiveClient({ url: 'ws://h/v1/wui/ws', WebSocketImpl: FakeWS }, { load: held.load })
    c.connect()
    const sent = c.send({ task_id: 't-9', body: 'hi', msg_id: 'm-1' })
    held.release()
    await tick()
    sockets[0].open()
    sockets[0].recv({ type: 'welcome', as: 'HUM-1' })
    const frame = sockets[0].sent.find((f) => f.type === 'send')
    assert.equal(frame.msg_id, 'm-1')
    sockets[0].recv({ type: 'ack', msg_id: 'm-1', cursor: 'k1' })
    const ack = await sent
    assert.equal(ack.msg_id, 'm-1')
  })

  it('close before the load reads closed at once and leaves no socket open', async () => {
    const { FakeWS, sockets } = fakeWs()
    const states = []
    const held = heldLoad()
    const c = lazyLiveClient({ url: 'ws://h/v1/wui/ws', WebSocketImpl: FakeWS, onState: (s) => states.push(s) }, { load: held.load })
    c.close()
    assert.equal(c.state, 'closed')
    held.release()
    await tick()
    assert.equal(sockets.length, 0)
    assert.equal(c.state, 'closed')
    assert.deepEqual(states, ['closed', 'closed'], 'onState hears closed at once, then from the real client')
  })

  it('onLoad runs once with the module and the real client (useLive starts watchLive there)', async () => {
    const { FakeWS } = fakeWs()
    const held = heldLoad()
    const seen = []
    const c = lazyLiveClient({ url: 'ws://h/v1/wui/ws', WebSocketImpl: FakeWS }, { load: held.load, onLoad: (mod, real) => seen.push([mod, real]) })
    c.connect()
    c.subscribe('a')
    held.release()
    await tick()
    c.subscribe('b')
    assert.equal(seen.length, 1)
    assert.equal(seen[0][0], liveWs)
    assert.equal(typeof seen[0][1].checkRevision, 'function')
  })

  it('a failed load is tried again by the next call; the kept calls wait for it', async () => {
    const { FakeWS, sockets } = fakeWs()
    let n = 0
    const load = () => (++n === 1 ? Promise.reject(new Error('chunk')) : Promise.resolve(liveWs))
    const c = lazyLiveClient({ url: 'ws://h/v1/wui/ws', WebSocketImpl: FakeWS }, { load })
    c.connect()
    await tick()
    assert.equal(sockets.length, 0, 'the first load failed')
    c.subscribe('t-1')
    await tick()
    assert.equal(n, 2, 'the next call loaded again')
    assert.equal(sockets.length, 1, 'the kept connect ran on the second load')
  })

  /** Timers the test fires by hand. */
  function handTimers() {
    const pending = []
    return {
      setTimer: (fn, ms) => { const t = { fn, ms }; pending.push(t); return t },
      clearTimer: (t) => { const i = pending.indexOf(t); if (i >= 0) pending.splice(i, 1) },
      fire: () => pending.splice(0).forEach((t) => t.fn()),
      pending,
    }
  }

  it('a failed load under a kept connect reads reconnecting and loads again on its own (R7 W1)', async () => {
    const { FakeWS, sockets } = fakeWs()
    const states = []
    const timers = handTimers()
    let n = 0
    const load = () => (++n === 1 ? Promise.reject(new Error('chunk')) : Promise.resolve(liveWs))
    const loaded = []
    const c = lazyLiveClient(
      { url: 'ws://h/v1/wui/ws', WebSocketImpl: FakeWS, onState: (s) => states.push(s), setTimer: timers.setTimer, clearTimer: timers.clearTimer, random: () => 0 },
      { load, onLoad: (mod) => loaded.push(mod) },
    )
    c.connect()
    await tick()
    assert.equal(c.state, 'reconnecting', 'a failed chunk load does not stay connecting')
    assert.deepEqual(states, ['connecting', 'reconnecting'])
    assert.equal(timers.pending.length, 1, 'one timed retry')
    assert.equal(timers.pending[0].ms, 250, 'the first wait is half of 500 ms with random 0')
    assert.equal(loaded.length, 0)

    timers.fire()
    await tick()
    assert.equal(n, 2, 'the timer loaded again with no other call')
    assert.equal(loaded.length, 1, 'onLoad ran: useLive starts watchLive there')
    assert.equal(sockets.length, 1, 'the kept connect dialled')
    assert.equal(c.state, 'connecting', 'the real client has the state now')
    assert.equal(timers.pending.length, 0)
  })

  it('each failed retry waits longer and stays reconnecting', async () => {
    const timers = handTimers()
    let n = 0
    const c = lazyLiveClient(
      { url: 'ws://h/v1/wui/ws', setTimer: timers.setTimer, clearTimer: timers.clearTimer, random: () => 0 },
      { load: () => { n++; return Promise.reject(new Error('chunk')) } },
    )
    c.connect()
    const waits = []
    for (let i = 0; i < 3; i++) {
      await tick()
      assert.equal(c.state, 'reconnecting')
      waits.push(timers.pending[0].ms)
      timers.fire()
    }
    assert.deepEqual(waits, [250, 500, 1000])
    assert.equal(n, 4, 'the first load and three timed retries')
  })

  it('a failed load after close stays closed and sets no retry', async () => {
    const timers = handTimers()
    const c = lazyLiveClient(
      { url: 'ws://h/v1/wui/ws', setTimer: timers.setTimer, clearTimer: timers.clearTimer },
      { load: () => Promise.reject(new Error('chunk')) },
    )
    c.connect()
    c.close()
    await tick()
    assert.equal(c.state, 'closed')
    assert.equal(timers.pending.length, 0)
  })

  it('close while a retry waits cancels it', async () => {
    const timers = handTimers()
    const c = lazyLiveClient(
      { url: 'ws://h/v1/wui/ws', setTimer: timers.setTimer, clearTimer: timers.clearTimer, random: () => 0 },
      { load: () => Promise.reject(new Error('chunk')) },
    )
    c.connect()
    await tick()
    assert.equal(timers.pending.length, 1)
    c.close()
    assert.equal(timers.pending.length, 0, 'the retry is cancelled')
    assert.equal(c.state, 'closed')
  })
})

describe('live-ws stays out of the entry chunk (SPL-6342)', () => {
  const useLive = read('../../src/composables/useLive.ts')
  const lazy = read('../../src/utils/live-ws-lazy.mjs')
  const code = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '').replace(/'[^'\n]*'/g, "''")
  const exported = [...read('../../src/utils/live-ws.mjs').matchAll(/^export (?:async )?(?:const|function) (\w+)/gm)].map((m) => m[1])

  it('useLive imports live-ws.mjs statically nowhere', () => {
    assert.ok(exported.includes('createLiveClient'), 'control: the export scan sees createLiveClient')
    assert.doesNotMatch(useLive, /^import[^\n]*live-ws\.mjs'/m)
  })

  it('useLive and live-ws-lazy.mjs name no live-ws export bare (a bare name is a Nuxt auto-import)', () => {
    for (const name of exported) {
      assert.doesNotMatch(code(useLive), bare(name), `useLive.ts: ${name}`)
      assert.doesNotMatch(code(lazy), bare(name), `live-ws-lazy.mjs: ${name}`)
    }
  })

  it('live-ws-lazy.mjs loads live-ws only with import() and exports one name', () => {
    assert.match(lazy, /import\('\.\/live-ws\.mjs'\)/)
    assert.doesNotMatch(lazy, /^import /m)
    assert.deepEqual([...lazy.matchAll(/^export (?:async )?(?:const|function) (\w+)/gm)].map((m) => m[1]), ['lazyLiveClient'])
  })

  it('the lazy client answers every method the real one has', () => {
    const real = liveWs.createLiveClient({ url: 'ws://h/v1/wui/ws', WebSocketImpl: class {} })
    const lazyC = lazyLiveClient({ url: 'ws://h/v1/wui/ws' }, { load: () => new Promise(() => {}) })
    assert.deepEqual(Object.keys(lazyC).sort(), Object.keys(real).sort())
  })
})
