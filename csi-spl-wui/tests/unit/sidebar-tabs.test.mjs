// The left stripe is two icon tabs: direct messages first (top), channels
// second. The stripe is at most 5% of the viewport.
//
// Run: node tests/unit/sidebar-tabs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { SIDE_TABS, tabForPath } from '../../src/utils/sidebar-tabs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('tabForPath', () => {
  it('direct messages are the first tab, channels the second', () => {
    assert.deepEqual([...SIDE_TABS], ['dm', 'channels'])
  })

  it('a DM route opens direct messages and a channel route opens channels', () => {
    assert.equal(tabForPath('/dm/HUM-1@box-wui'), 'dm')
    assert.equal(tabForPath('/fi/dm/CLE-07@box-a'), 'dm')
    assert.equal(tabForPath('/channel/tasks'), 'channels')
    assert.equal(tabForPath('/en/channel/lobby'), 'channels')
  })

  it('home, lobby, search and settings keep the reader\'s current tab', () => {
    for (const path of ['/', '/lobby', '/fi/lobby', '/search', '/settings', '/t/abc']) {
      assert.equal(tabForPath(path), null, path)
    }
  })

  it('does not treat a lookalike path as a tab', () => {
    assert.equal(tabForPath('/dmail'), null)
    assert.equal(tabForPath('/channels'), null)
  })
})

describe('the stripe is icons, direct messages on top', () => {
  const vue = src('src/components/ChannelSidebar.vue')
  const css = src('src/assets/css/main.css')
  const rail = vue.slice(vue.indexOf('class="sidebar-rail"'), vue.indexOf('class="sidebar-body"'))

  it('the DM control is the first tab and the channels control is the second', () => {
    const dm = vue.indexOf('data-testid="sidebar-tab-dm"')
    const ch = vue.indexOf('data-testid="sidebar-tab-channels"')
    assert.ok(dm > 0 && ch > dm)
    const panelDm = vue.indexOf('data-testid="sidebar-panel-dm"')
    const panelCh = vue.indexOf('data-testid="sidebar-panel-channels"')
    assert.ok(panelDm > 0 && panelCh > panelDm)
  })

  it('starts on direct messages', () => {
    assert.match(vue, /ref<SideTab>\('dm'\)/)
  })

  it('the stripe shows glyphs only — the names are the accessible name', () => {
    assert.match(rail, /<UiIcon name="messages"/)
    assert.match(rail, /<UiIcon name="hash"/)
    assert.match(rail, /:aria-label="t\('sidebar\.direct_messages'\)"/)
    assert.match(rail, /:aria-label="t\('sidebar\.channels'\)"/)
    assert.match(rail, /:title="t\('sidebar\.direct_messages'\)"/)
    assert.match(rail, /:title="t\('sidebar\.channels'\)"/)
    assert.doesNotMatch(rail, /\{\{\s*t\(/)
  })

  it('the stripe is at most 5% of the viewport and at most one icon wide', () => {
    assert.match(css, /\.sidebar-rail\s*\{[^}]*width:\s*min\(5vw,\s*48px\)/)
    assert.match(css, /\.sidebar-rail\s*\{[^}]*max-width:\s*min\(5vw,\s*48px\)/)
    assert.match(css, /\.sidebar-rail\s*\{[^}]*min-width:\s*0/)
    assert.equal(/\b100vw\b/.test(css), false)
  })

  it('the glyphs are path-only strokes', () => {
    const icons = src('src/utils/uiIcons.ts')
    assert.match(icons, /messages:\s*\[/)
    assert.match(icons, /hash:\s*\["M4 9h16", "M4 15h16", "M10 3 8 21", "M16 3 14 21"\]/)
  })
})
