// W4: the last three unconditional signed-out channel/roster reads
// (channel page, dm page, useSpoolEvents reconnect + mock poll).
// The plugin already owns the once-per-app gate (createShellBootstrap);
// these call sites reuse that module rather than a second rule.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createShellBootstrap } from '../../src/utils/shell-bootstrap.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('channel and dm pages do not duplicate the shell reads (W4)', () => {
  for (const page of ['src/pages/channel/[name].vue', 'src/pages/dm/[peer].vue']) {
    it(`${page}: no loadChannels / roster.refresh — the plugin's createShellBootstrap owns those`, () => {
      const s = src(page)
      assert.doesNotMatch(s, /loadChannels\(/)
      assert.doesNotMatch(s, /roster\.refresh\(/)
      assert.match(s, /events\.start\(/)
    })

    it(`${page}: the open feed waits for a member session (mock hydrates immediately)`, () => {
      const s = src(page)
      assert.match(s, /useSessionStore\(\)/)
      assert.match(s, /useSpoolApi\(\)/)
      assert.match(s, /if \(!api\.mock && String\(st\) !== 'in'\) return/)
    })
  }

  it('channel page still marks the open channel read', () => {
    assert.match(src('src/pages/channel/[name].vue'), /markRead/)
    assert.match(src('src/pages/channel/[name].vue'), /selectChannel/)
  })

  it('dm page still selects the open peer', () => {
    assert.match(src('src/pages/dm/[peer].vue'), /selectDm/)
  })
})

describe('useSpoolEvents reuses createShellBootstrap (W4)', () => {
  const ev = () => src('src/composables/useSpoolEvents.ts')

  it('imports the same gate the plugin uses', () => {
    const s = ev()
    assert.match(s, /createShellBootstrap\(/)
    assert.match(s, /from '~\/utils\/shell-bootstrap\.mjs'/)
  })

  it('mock tenant hydrates immediately via start(), then polls', () => {
    const s = ev()
    assert.match(s, /if \(api\.mock\) \{\s+timer = setInterval/)
    assert.match(s, /boot\.start\(/)
  })

  it('live reconnect catch-up of channels/roster goes through onSession, not a bare read', () => {
    const s = ev()
    assert.match(s, /live\.onReconnected\(/)
    assert.match(s, /boot\.onSession\(/)
    assert.match(s, /channel\.catchUp\(\)/)
    assert.doesNotMatch(s, /onReconnected\(\(\) => \{[^}]*loadChannels\(/s)
    assert.doesNotMatch(s, /onReconnected\(\(\) => \{[^}]*roster\.refresh\(/s)
  })
})

describe('the gate itself: reconnect-shaped calls stay once-per-session', () => {
  it('signed-out reconnects read nothing; signed-in reconnects read once', async () => {
    const n = { channels: 0, roster: 0 }
    const boot = createShellBootstrap({
      loadChannels: async () => { n.channels++ },
      refreshRoster: async () => { n.roster++ },
    })
    await boot.onSession('out')
    await boot.onSession('loading')
    assert.deepEqual(n, { channels: 0, roster: 0 })
    await boot.onSession('in')
    await boot.onSession('in')
    assert.deepEqual(n, { channels: 1, roster: 1 })
  })

  it('start() still hydrates the mock tenant with no session', async () => {
    const n = { channels: 0, roster: 0 }
    const boot = createShellBootstrap({
      loadChannels: async () => { n.channels++ },
      refreshRoster: async () => { n.roster++ },
    })
    await boot.start()
    await boot.start()
    assert.deepEqual(n, { channels: 1, roster: 1 })
  })
})
