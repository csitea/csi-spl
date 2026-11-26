// Spec 186 row M12 (c-001 ruling c04d54cc on s186 M11's finding 579017e1):
// the live socket's request half. `topic_select` and `multicast_check` are
// read-only frames the hub answers with `topic_selected` / `multicast_checked`
// by req_id (csi-spl-api hub/wui_multicast.go). Before M12 nothing in src
// called spool-client's setRequester, so on live both had no transport and
// M3 hid Select by title (13ba5725f). These tests drive the real live-ws
// client with a fake socket, through spool-client's setRequester, and read
// the plugin that wires them.
//
// Run: node --test tests/unit/live-ws-request.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import * as liveWs from '../../src/utils/live-ws.mjs'
import { lazyLiveClient } from '../../src/utils/live-ws-lazy.mjs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const { createLiveClient } = liveWs
const read = (rel) => readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8')
const REQ = '11111111-2222-4333-8444-555555555555'
const REQ2 = '66666666-7777-4888-9999-aaaaaaaaaaaa'

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
    timers,
  }
}

/** An open live client on a fake socket; `last()` is the newest frame it sent. */
function openClient(extra = {}) {
  const { FakeWS, sockets } = fakeWs()
  const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, ...extra })
  c.connect(); sockets[0].open(); sockets[0].recv({ type: 'welcome' })
  return { c, ws: sockets[0], last: () => sockets[0].sent.at(-1) }
}

const settled = (p) => p.then((v) => ({ ok: v }), (e) => ({ err: e }))

describe('live-ws request half (spec 186 M12)', () => {
  it('topic_select goes out as one frame and resolves on the topic_selected with its req_id', async () => {
    const { c, ws, last } = openClient()
    const p = c.request({ type: 'topic_select', req_id: REQ, action: 'multicast', task_ids: [], patterns: ['^ops'] })
    assert.deepEqual(last(), { type: 'topic_select', req_id: REQ, action: 'multicast', task_ids: [], patterns: ['^ops'] })
    ws.recv({ type: 'topic_selected', req_id: REQ2, ok: true, topics: [] }) // not ours: ignored
    ws.recv({ type: 'topic_selected', req_id: REQ, ok: true, topics: [{ task_id: 't1' }] })
    assert.deepEqual(await p, { type: 'topic_selected', req_id: REQ, ok: true, topics: [{ task_id: 't1' }] })
  })

  it('multicast_check resolves on multicast_checked; a missing req_id is minted', async () => {
    const { c, ws, last } = openClient()
    const p = c.request({ type: 'multicast_check', task_ids: ['a'], files: [], body: 'hi' })
    const sent = last()
    assert.equal(sent.type, 'multicast_check')
    assert.match(sent.req_id, /^[0-9a-f-]{8,}/)
    ws.recv({ type: 'multicast_checked', req_id: sent.req_id, ok: true, targets: [] })
    assert.equal((await p).type, 'multicast_checked')
  })

  it('a request made before the welcome is sent after it', async () => {
    const { FakeWS, sockets } = fakeWs()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS })
    c.connect()
    const p = c.request({ type: 'topic_select', req_id: REQ, action: 'multicast', task_ids: [], patterns: ['x'] })
    sockets[0].open()
    assert.equal(sockets[0].sent.some((f) => f.type === 'topic_select'), false)
    sockets[0].recv({ type: 'welcome' })
    assert.equal(sockets[0].sent.at(-1).req_id, REQ)
    sockets[0].recv({ type: 'topic_selected', req_id: REQ, ok: true, topics: [] })
    assert.equal((await p).ok, true)
  })

  it('a newer request of the same type supersedes the older (the hub cancels it unanswered); another type does not', async () => {
    const { c, ws } = openClient()
    const old = settled(c.request({ type: 'topic_select', req_id: REQ, patterns: ['a'] }))
    const mc = settled(c.request({ type: 'multicast_check', req_id: REQ2, task_ids: ['t'] }))
    const now = c.request({ type: 'topic_select', req_id: '00000000-0000-4000-8000-000000000001', patterns: ['b'] })
    assert.equal((await old).err.token, 'superseded')
    ws.recv({ type: 'multicast_checked', req_id: REQ2, ok: true, targets: [] })
    assert.equal((await mc).ok.ok, true)
    ws.recv({ type: 'topic_selected', req_id: '00000000-0000-4000-8000-000000000001', ok: true, topics: [] })
    assert.equal((await now).ok, true)
  })

  it('a close fails a waiting request with token closed', async () => {
    const { c, ws } = openClient()
    const p = settled(c.request({ type: 'topic_select', req_id: REQ, patterns: ['a'] }))
    ws.close()
    assert.equal((await p).err.token, 'closed')
  })

  it('no answer within requestTimeoutMs fails it with token timeout, and a queued frame is never sent late', async () => {
    const t = manualTimers()
    const { FakeWS, sockets } = fakeWs()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, setTimer: t.setTimer, clearTimer: t.clearTimer, requestTimeoutMs: 1234 })
    c.connect()
    const p = settled(c.request({ type: 'topic_select', req_id: REQ, patterns: ['a'] }))
    const timer = t.timers.find((x) => x.ms === 1234)
    assert.ok(timer, 'the request armed its own timer')
    timer.fn()
    assert.equal((await p).err.token, 'timeout')
    sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    assert.equal(sockets[0].sent.some((f) => f.type === 'topic_select'), false)
  })

  it('the lazy client forwards request once the socket code loads', async () => {
    const { FakeWS, sockets } = fakeWs()
    const c = lazyLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS }, { load: async () => liveWs })
    c.connect()
    const p = c.request({ type: 'topic_select', req_id: REQ, patterns: ['a'] })
    await new Promise((r) => setTimeout(r, 0))
    sockets[0].open(); sockets[0].recv({ type: 'welcome' })
    assert.equal(sockets[0].sent.at(-1).req_id, REQ)
    sockets[0].recv({ type: 'topic_selected', req_id: REQ, ok: true, topics: [] })
    assert.equal((await p).ok, true)
  })
})

describe('spool-client live: topic_select and multicast_check reach the hub over the request half (M12)', () => {
  it('a live client with the socket as its requester sends topic_select on the socket and returns the hub answer', async () => {
    const { c, ws, last } = openClient()
    const api = createSpoolClient({ fetchFn: async () => { throw new Error('no fetch') }, mock: false })
    api.setRequester((frame) => c.request(frame))
    assert.equal(api.canTopicSelect(), true)
    const p = api.topicSelect({ req_id: REQ, action: 'multicast', patterns: ['^ops'] })
    assert.equal(last().type, 'topic_select')
    assert.equal(last().req_id, REQ)
    ws.recv({ type: 'topic_selected', req_id: REQ, ok: true, topics: [{ task_id: 't9' }] })
    assert.deepEqual((await p).topics, [{ task_id: 't9' }])
  })
})

describe('the live plugin wires the request half (plugins/spool-live.client.ts)', () => {
  const plugin = read('../../src/plugins/spool-live.client.ts')
  it('sets the requester to the socket client request, at plugin setup (before any component reads canTopicSelect)', () => {
    assert.match(plugin, /\.setRequester\(\(frame\) => \{\s+const client = live\.ensure\(\)/)
    assert.match(plugin, /return client\.request\(frame\)/)
    assert.ok(plugin.indexOf('.setRequester(') < plugin.indexOf('function start()'), 'set at setup, not behind the session gate')
    assert.ok(plugin.indexOf('if (api.mock) return') < plugin.indexOf('.setRequester('), 'the mock answers itself, it gets no requester')
  })
  it('a tab with no socket answers no_socket, never a hang', () => {
    assert.match(plugin, /if \(!client\) return Promise\.reject\(Object\.assign\(new Error\('no WUI socket'\), \{ status: 0, token: 'no_socket' \}\)\)/)
  })
})
