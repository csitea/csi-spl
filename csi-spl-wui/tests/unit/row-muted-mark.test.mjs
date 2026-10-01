/* CLE-77851: a muted sidebar row is marked by a muted bell, not by fading.
   csitea #csi-fina: a member saw her own channel pale (opacity 0.55, the only
   "muted" cue) and read it as "inactive / not a member". */
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const sidebar = readFileSync(join(WUI, 'src/components/ChannelSidebar.vue'), 'utf8')
const mark = readFileSync(join(WUI, 'src/components/RowMutedButton.vue'), 'utf8')
const LOCALES = join(WUI, 'i18n/locales')

describe('muted row mark (CLE-77851)', () => {
  it('a muted row is not faded: no opacity on .nav-row--muted', () => {
    const rules = [...sidebar.matchAll(/([^{}]*\.nav-row--muted[^{}]*)\{([^}]*)\}/g)]
    assert.ok(rules.length > 0, 'the .nav-row--muted rule is still there')
    for (const [, sel, body] of rules) {
      assert.doesNotMatch(body, /opacity|filter|color:/, `${sel.trim()} must not fade the row`)
    }
  })

  it('every muted channel and DM row (channels, DMs) carries the muted bell', () => {
    const uses = [...sidebar.matchAll(/<RowMutedButton v-if="([^"]+)"[^>]*@unmute="([^"]+)"/g)]
    const conds = uses.map((u) => u[1]).sort()
    assert.deepEqual(conds, [
      'isChannelMuted(c.channel_id)',
      'mutedPeers[p.label]',
    ])
    for (const [, cond, unmute] of uses) {
      assert.match(unmute, cond.startsWith('isChannelMuted') ? /^toggleChannelMute\(/ : /^togglePeer\('mute', /, `${cond} unmutes on click`)
    }
  })

  it('the bell is a named button that unmutes, with a bell-off icon', () => {
    assert.match(mark, /<button[\s\S]*type="button"/)
    assert.match(mark, /data-testid="row-muted"/)
    assert.match(mark, /:aria-label="label"/)
    assert.match(mark, /name="bell-off"/)
    assert.match(mark, /emit\('unmute'\)/)
    assert.match(mark, /t\('sidebar\.row_muted', \{ name: props\.name \}\)/)
  })

  it('every locale names the muted state with the row name', () => {
    const files = readdirSync(LOCALES).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const v = JSON.parse(readFileSync(join(LOCALES, f), 'utf8')).sidebar?.row_muted
      assert.equal(typeof v, 'string', `${f} sidebar.row_muted`)
      assert.ok(v.includes('{name}'), `${f} sidebar.row_muted names the row`)
    }
  })
})
