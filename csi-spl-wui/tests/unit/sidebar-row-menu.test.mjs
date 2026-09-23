// Left-pane row menu: three-line button on each object, not on the icon tabs.
// Run: node tests/unit/sidebar-row-menu.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { rowMenuItems } from '../../src/utils/sidebar-row-menu.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('rowMenuItems', () => {
  it('offers open and copy, and mark-as-read only when the row is unread', () => {
    assert.deepEqual(rowMenuItems(false).map((i) => i.id), ['open', 'copy'])
    assert.deepEqual(rowMenuItems(true).map((i) => i.id), ['open', 'copy', 'read'])
  })
})

describe('the menu sits on objects, not the tab rail', () => {
  const vue = src('src/components/ChannelSidebar.vue')
  const menu = src('src/components/SidebarRowMenu.vue')
  const icons = src('src/utils/uiIcons.ts')

  it('each list row has a menu and the icon rail does not', () => {
    const rail = vue.slice(vue.indexOf('class="sidebar-rail"'), vue.indexOf('class="sidebar-body"'))
    assert.doesNotMatch(rail, /SidebarRowMenu/)
    const self = vue.slice(vue.indexOf('data-testid="people-self"'), vue.indexOf('v-for="p in peers"'))
    assert.doesNotMatch(self, /SidebarRowMenu/)
    const markers = [
      'v-for="p in peers"',
      'v-for="c in channel.ordered"',
      'v-for="row in viewer.threads"',
      "row.kind === 'channel'",
      "row.kind === 'dm'",
      'v-else',
    ]
    let at = 0
    for (const marker of markers) {
      const i = vue.indexOf(marker, at)
      const menu = vue.indexOf('<SidebarRowMenu', i)
      assert.ok(i > at && menu > i, marker)
      at = menu
    }
    assert.equal(vue.split('<SidebarRowMenu').length - 1, 6)
  })

  it('the button is three lines and becomes an X while open', () => {
    assert.match(menu, /:name="open \? 'x' : 'menu'"/)
    assert.match(menu, /@click\.stop="emit\('toggle'\)"/)
    assert.match(menu, /aria-haspopup="menu"/)
    assert.match(icons, /menu: \["M4 6h16", "M4 12h16", "M4 18h16"\]/)
  })
})
