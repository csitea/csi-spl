import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  applyPresence,
  catchUp,
  doorModes,
  isDoor,
  lastCursor,
  newRows,
  signInHref,
  splitPeer,
  withSessionRetry,
} from '../../src/utils/live-follow.mjs'
import { createLiveClient } from '../../src/utils/live-ws.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

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
    setTimer: (fn, ms) => { const t = { fn, ms }; timers.push(t); return t },
    clearTimer: () => {},
    fire: (i) => timers[i].fn(),
    timers,
  }
}

const row = (id, cursor, at) => ({ msg_id: id, cursor, received_at: at, kind: 'note', body: id })

describe('reconnect catch-up (wui-live-ws §7, view-v1 §4.4)', () => {
  it('the last cursor is the newest received row, skipping rows without one', () => {
    const rows = [row('b', 'c2', '2026-09-19T10:00:02Z'), row('a', 'c1', '2026-09-19T10:00:01Z'), { msg_id: 'local' }]
    assert.equal(lastCursor(rows), 'c2')
    assert.equal(lastCursor([{ msg_id: 'x' }]), '')
    assert.equal(lastCursor([]), '')
  })

  it('dedupes by msg_id against held rows and within the batch', () => {
    const held = [row('a', 'c1', 't1')]
    assert.deepEqual(newRows(held, [row('a', 'c1', 't1'), row('b', 'c2', 't2'), row('b', 'c2', 't2'), { body: 'no id' }]).map((m) => m.msg_id), ['b'])
  })

  it('a simulated reconnect fetches after=<last cursor> once and dedupes', async () => {
    const { FakeWS, sockets } = fakeWs()
    const timers = manualTimers()
    const held = [row('a', 'c1', '2026-09-19T10:00:01Z'), row('b', 'c2', '2026-09-19T10:00:02Z')]
    const calls = []
    const getThread = async (id, opts) => {
      calls.push({ id, ...opts })
      // the hub returns rows after c2; one of them the socket already delivered
      return { messages: [row('b', 'c2', '2026-09-19T10:00:02Z'), row('c', 'c3', '2026-09-19T10:00:03Z')] }
    }
    const pending = []
    const onReconnected = () => {
      pending.push(catchUp(getThread, 'T1', held).then((r) => { if (r) held.push(...r.rows) }))
    }
    const c = createLiveClient({ url: 'ws://x/v1/wui/ws', WebSocketImpl: FakeWS, onReconnected, setTimer: timers.setTimer, clearTimer: timers.clearTimer })
    c.connect()
    c.subscribe('T1')
    sockets[0].open()
    sockets[0].recv({ type: 'welcome', as: 'HUM-1' })
    assert.equal(calls.length, 0, 'the first welcome is not a reconnect')

    sockets[0].close()
    assert.equal(c.state, 'reconnecting')
    timers.fire(0)
    sockets[1].open()
    sockets[1].recv({ type: 'welcome', as: 'HUM-1' })
    await Promise.all(pending)

    assert.deepEqual(calls, [{ id: 'T1', after: 'c2', limit: 200 }])
    assert.deepEqual(held.map((m) => m.msg_id), ['a', 'b', 'c'])
    assert.ok(sockets[1].sent.some((f) => f.type === 'subscribe' && f.task_id === 'T1'), 're-subscribed')
  })

  it('no cursor held → no catch-up call (the caller re-opens)', async () => {
    let n = 0
    assert.equal(await catchUp(async () => { n++; return { messages: [] } }, 'T1', [{ msg_id: 'x' }]), null)
    assert.equal(n, 0)
  })

  it('the live store wires the reconnect to a catch-up', () => {
    const live = src('src/stores/live.ts')
    assert.match(live, /catchUp\(/)
    assert.match(live, /onReconnected\(/)
    const useLive = src('src/composables/useLive.ts')
    assert.match(useLive, /onReconnected: \(\) =>/)
    assert.match(useLive, /onPresence: \(f\) =>/)
  })
})

describe('door UX (view-v1 §2: a 401 view_door is a prompt)', () => {
  const door401 = () => Object.assign(new Error('spool 401 view_door'), { status: 401, token: 'view_door', detail: 'a view token or a member session is required' })
  const fakeApi = () => ({ door: '', setDoor(d) { this.door = d } })

  it('session door: one retry with credentials include succeeds', async () => {
    const api = fakeApi()
    let n = 0
    const out = await withSessionRetry(api, async () => { n++; if (api.door !== 'session') throw door401(); return 'rows' })
    assert.equal(out, 'rows')
    assert.equal(n, 2)
    assert.equal(api.door, 'session')
  })

  it('token door: a CORS-refused retry restores the door and rethrows the 401', async () => {
    const api = fakeApi()
    let n = 0
    await assert.rejects(
      withSessionRetry(api, async () => { n++; if (api.door === 'session') throw new TypeError('Failed to fetch'); throw door401() }),
      (e) => e.status === 401 && e.token === 'view_door',
    )
    assert.equal(n, 2)
    assert.equal(api.door, '')
  })

  it('no retry for a non-door error or when already in session mode', async () => {
    const api = fakeApi()
    let n = 0
    await assert.rejects(withSessionRetry(api, async () => { n++; throw Object.assign(new Error('x'), { status: 500 }) }))
    api.door = 'session'
    await assert.rejects(withSessionRetry(api, async () => { n++; throw door401() }))
    assert.equal(n, 2)
  })

  /*
   * CLE-3415: the shell fires several reads at once (channels + roster from the
   * bootstrap plugin, a thread from the pane). The door used to be read in the
   * catch, so a caller whose 401 landed AFTER a sibling had switched the door
   * saw door === 'session' and rethrew a 401 the retry would have answered —
   * on prd the channel list stayed empty for a poll.
   */
  it('a read that went out before a sibling armed the door still retries', async () => {
    const api = fakeApi()
    let n = 0
    const out = await withSessionRetry(api, async () => {
      n++
      if (n === 1) {
        api.door = 'session' /* a sibling armed it while this read was in flight */
        throw door401()
      }
      return 'rows'
    })
    assert.equal(out, 'rows')
    assert.equal(n, 2)
  })

  it('two concurrent reads share ONE arming of the door and both resolve', async () => {
    const api = fakeApi()
    let armings = 0
    api.setDoor = function (d) { armings++; this.door = d }
    const gate = []
    const calls = { channels: 0, roster: 0 }
    const read = (what) => async () => {
      calls[what]++
      if (api.door === 'session') return what
      await new Promise((r) => gate.push(r))
      throw door401()
    }
    const both = [withSessionRetry(api, read('channels')), withSessionRetry(api, read('roster'))]
    await new Promise((r) => setTimeout(r, 0))
    assert.equal(gate.length, 2, 'both reads went out before either 401 landed')
    for (const release of gate.splice(0)) release()
    assert.deepEqual(await Promise.all(both), ['channels', 'roster'])
    assert.equal(armings, 1, 'one door arming, shared by both callers')
    /* each caller re-issues its OWN url: the arming is shared, the read is not */
    assert.deepEqual(calls, { channels: 2, roster: 2 })
  })

  it('a token door refuses both concurrent retries once, restores the door and rethrows the 401', async () => {
    const api = fakeApi()
    let retries = 0
    const gate = []
    const read = async () => {
      if (api.door === 'session') { retries++; throw new TypeError('Failed to fetch') }
      await new Promise((r) => gate.push(r))
      throw door401()
    }
    const both = [withSessionRetry(api, read), withSessionRetry(api, read)]
    await new Promise((r) => setTimeout(r, 0))
    for (const release of gate.splice(0)) release()
    const settled = await Promise.allSettled(both)
    for (const r of settled) {
      assert.equal(r.status, 'rejected')
      assert.equal(r.reason.status, 401)
      assert.equal(r.reason.token, 'view_door')
    }
    assert.equal(retries, 1, 'only the first caller tried the credentialed retry')
    assert.equal(api.door, '', 'the door is restored for the prompt (901ea06)')
  })

  it('a restored door lets the NEXT 401 arm again', async () => {
    const api = fakeApi()
    await assert.rejects(withSessionRetry(api, async () => {
      if (api.door === 'session') throw new TypeError('Failed to fetch')
      throw door401()
    }))
    assert.equal(api.door, '')
    let n = 0
    assert.equal(await withSessionRetry(api, async () => { n++; if (api.door !== 'session') throw door401(); return 'rows' }), 'rows')
    assert.equal(n, 2)
  })

  it('the live and viewer stores read through withSessionRetry', () => {
    for (const f of ['src/stores/live.ts', 'src/stores/viewer.ts']) assert.match(src(f), /withSessionRetry\(api,/, f)
  })

  it('recognises the door and nothing else', () => {
    assert.equal(isDoor({ status: 401, token: 'view_door' }), true)
    assert.equal(isDoor({ status: 401 }), true)
    assert.equal(isDoor({ status: 401, token: 'door' }), false)
    assert.equal(isDoor({ status: 404, token: 'view_door' }), false)
    assert.equal(isDoor(null), false)
  })

  it('derives the ways in from the 401 detail', () => {
    assert.deepEqual(doorModes('a view token or a member session is required'), { session: true, token: true })
    assert.deepEqual(doorModes('a member session is required'), { session: true, token: false })
    assert.deepEqual(doorModes('a view token is required'), { session: false, token: true })
    assert.deepEqual(doorModes(''), { session: true, token: true })
  })

  it('the sign-in link carries redirect and tenant', () => {
    assert.equal(signInHref('/t/abc', 't1'), '/login?redirect=%2Ft%2Fabc&tenant=t1')
    assert.equal(signInHref('/lobby', ''), '/login?redirect=%2Flobby')
    assert.equal(signInHref('//evil.example.com', 't1'), '/login?redirect=%2F&tenant=t1')
    assert.equal(signInHref('/login?x=1', 'Bad Tenant'), '/login?redirect=%2F')
  })

  it('/t, /lobby, / and the thread pane render the door prompt', () => {
    for (const f of ['src/pages/t/[task_id].vue', 'src/pages/lobby.vue', 'src/pages/index.vue', 'src/components/LiveThreadPane.vue']) {
      assert.match(src(f), /<ViewTokenForm/, f)
    }
    assert.match(src('src/components/ViewTokenForm.vue'), /signInHref\(/)
  })
})

describe('verbosity on /t (005 FR-013)', () => {
  it('/t/[task_id] has the selector and filters its replies', () => {
    const page = src('src/pages/t/[task_id].vue')
    assert.match(page, /<VerbositySelector/)
    assert.match(page, /applyVerbosity\(/)
  })
})

describe('presence (wui-live-ws §3, channels-v1 §6)', () => {
  it('a presence frame flips online, last writer wins', () => {
    let on = ['CLE-07@box-a']
    on = applyPresence(on, { type: 'presence', peer: 'HUM-2@box-wui', status: 'online' })
    assert.deepEqual(on, ['CLE-07@box-a', 'HUM-2@box-wui'])
    on = applyPresence(on, { type: 'presence', peer: 'CLE-07@box-a', status: 'offline' })
    assert.deepEqual(on, ['HUM-2@box-wui'])
    const same = applyPresence(on, { type: 'presence', peer: 'HUM-2@box-wui', status: 'online' })
    assert.equal(same, on, 'a repeat is a no-op')
    assert.equal(applyPresence(on, { type: 'message', peer: 'X-1@b', status: 'online' }), on)
    assert.equal(applyPresence(on, { type: 'presence', peer: 'X-1@b', status: 'away' }), on)
  })

  it('splits peer labels', () => {
    assert.deepEqual(splitPeer('HUM-2@box-wui'), { id: 'HUM-2', box: 'box-wui' })
    assert.deepEqual(splitPeer('CLE-07'), { id: 'CLE-07', box: '' })
  })

  it('the roster applies presence and lists online humans', () => {
    const roster = src('src/stores/roster.ts')
    assert.match(roster, /applyPresence\(/)
    assert.match(roster, /splitPeer\(/)
  })

  it('live-ws hands presence frames to onPresence (A1 2b74ce3)', () => {
    const { FakeWS, sockets } = fakeWs()
    const seen = []
    const c = createLiveClient({ url: 'ws://x/v1/wui/ws', WebSocketImpl: FakeWS, onPresence: (f) => seen.push(f) })
    c.connect()
    sockets[0].open()
    sockets[0].recv({ type: 'welcome', as: 'HUM-1' })
    sockets[0].recv({ type: 'presence', peer: 'HUM-2@box-wui', status: 'online' })
    assert.equal(seen.length, 1)
    assert.equal(seen[0].peer, 'HUM-2@box-wui')
  })
})
