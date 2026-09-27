// W5: the WUI must not open the hub WUI socket while signed out.
// Predicate + close/resume helpers live in shell-bootstrap.mjs (the same
// session gate as the channel/roster reads). Call sites: lobby.vue and
// useSpoolEvents.start().
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { shouldOpenHubSocket, startHubSocket, stopHubSocket } from '../../src/utils/shell-bootstrap.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('shouldOpenHubSocket (W5)', () => {
  it('live: only a member session', () => {
    for (const st of ['loading', 'unknown', 'out', '', null, undefined]) {
      assert.equal(shouldOpenHubSocket(st), false, st)
    }
    assert.equal(shouldOpenHubSocket('in'), true)
  })

  it('mock tenant never opens a hub socket', () => {
    assert.equal(shouldOpenHubSocket('in', true), false)
    assert.equal(shouldOpenHubSocket('out', true), false)
  })
})

describe('startHubSocket / stopHubSocket (W5)', () => {
  function fakeLive(state, clientState = 'connecting') {
    const client = {
      state: clientState,
      connectCalls: 0,
      closeCalls: 0,
      connect() { this.connectCalls++; this.state = 'connecting' },
      close() { this.closeCalls++; this.state = 'closed' },
    }
    const live = {
      state: { value: state },
      ensureCalls: 0,
      client,
      ensure() { this.ensureCalls++; return this.client },
    }
    return { live, client }
  }

  it('stop from idle does not construct a client', () => {
    const { live, client } = fakeLive('idle')
    stopHubSocket(live)
    assert.equal(live.ensureCalls, 0)
    assert.equal(client.closeCalls, 0)
  })

  it('stop from connecting/open/reconnecting closes so it does not retry', () => {
    for (const s of ['connecting', 'open', 'reconnecting']) {
      const { live, client } = fakeLive(s, s)
      stopHubSocket(live)
      assert.equal(live.ensureCalls, 1, s)
      assert.equal(client.closeCalls, 1, s)
    }
  })

  it('start ensure()s; a closed client is connect()ed again', () => {
    const { live, client } = fakeLive('closed', 'closed')
    startHubSocket(live)
    assert.equal(live.ensureCalls, 1)
    assert.equal(client.connectCalls, 1)
  })

  it('start on an already-connecting client does not connect twice', () => {
    const { live, client } = fakeLive('connecting', 'connecting')
    startHubSocket(live)
    assert.equal(live.ensureCalls, 1)
    assert.equal(client.connectCalls, 0)
  })
})

describe('lobby.vue gates the socket (W5)', () => {
  const s = () => src('src/pages/lobby.vue')

  it('does not call live.ensure() from onMounted', () => {
    const t = s()
    const m = t.match(/onMounted\(\(\) => \{([\s\S]*?)\n\}\)/)
    assert.ok(m, 'onMounted block')
    assert.equal(m[1].includes('live.ensure('), false)
    assert.match(m[1], /notes\.markRead/)
  })

  it('watches session.state with the shared predicate (sign-in without reload)', () => {
    const t = s()
    assert.match(t, /useSessionStore\(\)/)
    assert.match(t, /useSpoolApi\(\)/)
    assert.match(t, /shouldOpenHubSocket\(/)
    assert.match(t, /startHubSocket\(live\)/)
    assert.match(t, /stopHubSocket\(live\)/)
    assert.match(t, /watch\(\[lobbyId, \(\) => session\.state\]/)
    assert.match(t, /immediate:\s*true/)
  })

  it('mock tenant still hydrates immediately (no hub socket)', () => {
    assert.match(s(), /if \(api\.mock\) \{\s+live\.ensure\(\)/)
  })

  it('store.open sits behind the same gate (it also ensure()s)', () => {
    const t = s()
    assert.match(t, /shouldOpenHubSocket\(st\)\) \{[\s\S]*store\.open\(id[,)]/)
    assert.doesNotMatch(t, /watch\(lobbyId, \(id\) => \{ if \(id\) void store\.open/)
  })
})

describe('useSpoolEvents.start gates the socket (W5)', () => {
  const s = () => src('src/composables/useSpoolEvents.ts')

  it('imports the shared gate, not a second rule', () => {
    const t = s()
    assert.match(t, /shouldOpenHubSocket/)
    assert.match(t, /startHubSocket/)
    assert.match(t, /stopHubSocket/)
    assert.match(t, /from '~\/utils\/shell-bootstrap\.mjs'/)
  })

  it('live.ensure is not called until the session watch says in', () => {
    const t = s()
    assert.match(t, /watch\(\(\) => session\.state/)
    assert.match(t, /if \(shouldOpenHubSocket\(st\)\) attach\(\)/)
    assert.match(t, /else detach\(\)/)
    assert.match(t, /immediate:\s*true/)
    /* CONTROL: the mock branch never ensure()s — it polls */
    const mock = t.match(/if \(api\.mock\) \{[\s\S]*?return\n    \}/)
    assert.ok(mock, 'mock branch')
    assert.equal(mock[0].includes('live.ensure('), false)
  })

  it('sign-out detaches and closes; reconnect catch-up still uses onSession', () => {
    const t = s()
    assert.match(t, /stopHubSocket\(live\)/)
    assert.match(t, /live.onReconnected\(/)
    assert.match(t, /boot.onSession\(/)
    assert.match(t, /channel.ingestLive\(m\)/)
    assert.match(t, /channel.catchUp\(\)/)
  })
})
