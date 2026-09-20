// The bootstrap gate (CLE-3374): the channel list and the roster both need a
// member session, so the plugin used to answer 401 view_door twice on every
// page load — including /login, which has no shell to fill.
//
// The decision is EXECUTED here (createShellBootstrap); the Nuxt wiring around
// it — client-only, the session store, the mock shortcut — is asserted on the
// plugin source, as channel-door.test.mjs does for the stores.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createShellBootstrap } from '../../src/utils/shell-bootstrap.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

/** Counts what actually went to the hub. */
function spy() {
  const n = { channels: 0, roster: 0 }
  const boot = createShellBootstrap({
    loadChannels: async () => { n.channels++ },
    refreshRoster: async () => { n.roster++ },
  })
  return { n, boot }
}

describe('shell bootstrap: no hub read without a session (CLE-3374)', () => {
  it('signed out — no channel or roster request, whatever the probe says', async () => {
    const { n, boot } = spy()
    for (const state of ['loading', 'unknown', 'out', 'loading', 'out']) await boot.onSession(state)
    assert.deepEqual(n, { channels: 0, roster: 0 })
    assert.equal(boot.started, false)
  })

  it('signed in — exactly one of each, however many times the state is seen', async () => {
    const { n, boot } = spy()
    await boot.onSession('out')
    await boot.onSession('in')
    assert.deepEqual(n, { channels: 1, roster: 1 })
    /* a re-probe, a claims refresh, a route change: still one each */
    await boot.onSession('in')
    await boot.onSession('in')
    assert.deepEqual(n, { channels: 1, roster: 1 })
    assert.equal(boot.started, true)
  })

  it('a human who signs in gets the reads without a reload', async () => {
    const { n, boot } = spy()
    await boot.onSession('loading')
    await boot.onSession('out')
    assert.deepEqual(n, { channels: 0, roster: 0 })
    await boot.onSession('in') /* NativeAuthForm adopts the claims */
    assert.deepEqual(n, { channels: 1, roster: 1 })
  })

  it('a failing read is swallowed, not an unhandled rejection', async () => {
    let seen = null
    const boot = createShellBootstrap({
      loadChannels: async () => { throw Object.assign(new Error('spool 401'), { status: 401 }) },
      refreshRoster: async () => {},
      onError: (e) => { seen = e },
    })
    await boot.onSession('in')
    assert.equal(seen && seen.status, 401)
  })

  it('start() is the mock path: one load, no session needed', async () => {
    const { n, boot } = spy()
    await boot.start()
    await boot.start()
    assert.deepEqual(n, { channels: 1, roster: 1 })
  })
})

describe('the bootstrap plugin wires that gate', () => {
  const plugin = () => src('src/plugins/spool-bootstrap.ts')

  it('never reads on the server, and reads nothing on its own', () => {
    const p = plugin()
    assert.match(p, /if \(!import\.meta\.client\) return/)
    assert.match(p, /createShellBootstrap\(/)
    /* the loads belong to the gate, never to the plugin body */
    assert.doesNotMatch(p, /await Promise\.all\(\[/)
  })

  it('gates on the session store, not on a probe of its own', () => {
    const p = plugin()
    assert.match(p, /useSessionStore\(\)/)
    assert.match(p, /watch\(\(\) => session\.state,/)
    /* a probe here would be a THIRD request on a signed-out /login load */
    assert.doesNotMatch(p, /session\.probe\(/)
  })

  it('keeps the mock tenant hydrating without a session', () => {
    assert.match(plugin(), /useSpoolApi\(\)\.mock/)
  })
})
