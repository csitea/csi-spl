// Left-pane row menu: three-line button on each object, not on the icon tabs.
// Run: node tests/unit/sidebar-row-menu.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { rowMenuAdmin, rowMenuItems } from '../../src/utils/sidebar-row-menu.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('rowMenuItems', () => {
  it('offers open and copy, and mark-as-read only when the row is unread', () => {
    assert.deepEqual(rowMenuItems(false).map((i) => i.id), ['open', 'copy'])
    assert.deepEqual(rowMenuItems(true).map((i) => i.id), ['open', 'copy', 'read'])
  })

  it('people and bots get block and mute, and remove only for an admin', () => {
    const person = rowMenuItems(false, { person: true }).map((i) => i.id)
    assert.deepEqual(person, ['open', 'copy', 'block', 'mute'])
    const admin = rowMenuItems(true, { person: true, admin: true }).map((i) => i.id)
    assert.deepEqual(admin, ['open', 'copy', 'read', 'block', 'mute', 'remove'])
    assert.equal(rowMenuItems(false, { person: true, blocked: true })[2].labelKey, 'sidebar.row_menu.unblock')
    assert.equal(rowMenuItems(false, { person: true, muted: true })[3].labelKey, 'sidebar.row_menu.unmute')
  })

  it('remove stays closed unless the signed-in role is admin or the tenant owner', () => {
    assert.equal(rowMenuAdmin(null), false)
    assert.equal(rowMenuAdmin({ role: 'developer', tenantOwner: false }), false)
    assert.equal(rowMenuAdmin({ role: 'tester' }), false)
    assert.equal(rowMenuAdmin({ role: 'admin', tenantOwner: false }), true)
    assert.equal(rowMenuAdmin({ role: 'biz_owner', tenantOwner: true }), true)
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
    assert.equal(vue.split(':person="true"').length - 1, 2)
    const ch = vue.indexOf('v-for="c in channel.ordered"')
    const th = vue.indexOf('v-for="row in viewer.threads"')
    assert.equal(vue.slice(ch, th).includes(':person="true"'), false)
  })

  it('the button is three lines and becomes an X while open', () => {
    assert.match(menu, /:name="open \? 'x' : 'menu'"/)
    assert.match(menu, /@click\.stop="emit\('toggle'\)"/)
    assert.match(menu, /aria-haspopup="menu"/)
    assert.match(icons, /menu: \["M4 6h16", "M4 12h16", "M4 18h16"\]/)
  })
})
