// Left-pane row menu: three-line button on each object, not on the icon tabs.
// Run: node tests/unit/sidebar-row-menu.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { dropIndex, moveKey, pinRows, rowMenuAdmin, rowMenuItems } from '../../src/utils/sidebar-row-menu.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('rowMenuItems', () => {
  it('offers open and copy, and mark-as-read only when the row is unread', () => {
    assert.deepEqual(rowMenuItems(false).map((i) => i.id), ['open', 'copy'])
    assert.deepEqual(rowMenuItems(true).map((i) => i.id), ['open', 'copy', 'read'])
    assert.deepEqual(rowMenuItems(true).map((i) => i.icon), ['open', 'copy', 'check'])
  })

  it('people and bots get block and mute, and remove only for an admin', () => {
    const person = rowMenuItems(false, { person: true }).map((i) => i.id)
    assert.deepEqual(person, ['open', 'copy', 'block', 'mute', 'pin'])
    const admin = rowMenuItems(true, { person: true, admin: true }).map((i) => i.id)
    assert.deepEqual(admin, ['open', 'copy', 'read', 'block', 'mute', 'pin', 'remove'])
    assert.equal(rowMenuItems(false, { person: true, blocked: true })[2].labelKey, 'sidebar.row_menu.unblock')
    assert.equal(rowMenuItems(false, { person: true, muted: true })[3].labelKey, 'sidebar.row_menu.unmute')
    assert.equal(rowMenuItems(false, { person: true, pinned: true })[4].labelKey, 'sidebar.row_menu.unpin')
    assert.equal(rowMenuItems(false).some((i) => i.id === 'pin'), false)
  })

  it('remove stays closed unless the signed-in role is admin or the tenant owner', () => {
    assert.equal(rowMenuAdmin(null), false)
    assert.equal(rowMenuAdmin({ role: 'developer', tenantOwner: false }), false)
    assert.equal(rowMenuAdmin({ role: 'tester' }), false)
    assert.equal(rowMenuAdmin({ role: 'admin', tenantOwner: false }), true)
    assert.equal(rowMenuAdmin({ role: 'biz_owner', tenantOwner: true }), true)
  })

  it('every action has an icon and a catalogue name', () => {
    const items = rowMenuItems(true, { person: true, admin: true, blocked: true, muted: true })
    assert.deepEqual(items.map((i) => i.icon), ['open', 'copy', 'check', 'user-check', 'bell', 'pin', 'trash'])
    for (const item of items) {
      assert.match(item.labelKey, /^sidebar\.row_menu\./)
    }
    const menu = src('src/components/SidebarRowMenu.vue')
    assert.match(menu, /<UiIcon :name="item\.icon"/)
    assert.match(menu, /\{\{ t\(item\.labelKey\) \}\}/)
  })
})

describe('the language switcher changes the row-menu names', () => {
  it('every locale translates the action names', () => {
    const dir = join(WUI, 'i18n/locales')
    const en = JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8')).sidebar.row_menu
    const codes = ['bg', 'el', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']
    for (const code of codes) {
      const row = JSON.parse(readFileSync(join(dir, code + '.json'), 'utf8')).sidebar.row_menu
      for (const key of Object.keys(en)) {
        if (key === 'properties') {
          assert.equal(row[key], 'Properties', code + ' ' + key)
          continue
        }
        assert.notEqual(row[key], en[key], code + ' ' + key)
        assert.equal(row[key].includes('{name}'), en[key].includes('{name}'), code + ' ' + key)
      }
    }
  })

  it('the channel and direct-message headings explain the rows in every language', () => {
    const dir = join(WUI, 'i18n/locales')
    const vue = src('src/components/ChannelSidebar.vue')
    assert.match(vue, /t\('sidebar\.help\.channels'\)/)
    assert.match(vue, /t\('sidebar\.help\.direct_messages'\)/)
    assert.match(vue, /data-testid="sidebar-help-channels"/)
    assert.match(vue, /data-testid="sidebar-help-dm"/)
    const en = JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8')).sidebar.help
    const codes = ['bg', 'el', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']
    for (const code of codes) {
      const help = JSON.parse(readFileSync(join(dir, code + '.json'), 'utf8')).sidebar.help
      for (const key of ['channels', 'direct_messages']) {
        assert.equal(typeof help[key], 'string', code + ' ' + key)
        assert.ok(help[key].length > 20, code + ' ' + key)
        assert.notEqual(help[key], en[key], code + ' ' + key)
      }
    }
  })
})

describe('pinRows', () => {
  it('puts pinned labels first, newest pin at the top, and keeps the rest', () => {
    const rows = [{ label: 'a' }, { label: 'b' }, { label: 'c' }, { label: 'd' }]
    assert.deepEqual(pinRows(rows, ['c', 'a']).map((r) => r.label), ['c', 'a', 'b', 'd'])
    assert.deepEqual(pinRows(rows, []).map((r) => r.label), ['a', 'b', 'c', 'd'])
    assert.deepEqual(pinRows(rows, ['missing', 'b']).map((r) => r.label), ['b', 'a', 'c', 'd'])
    const withNew = [{ label: 'new' }, { label: 'a' }, { label: 'b' }]
    assert.deepEqual(pinRows(withNew, ['b', 'a']).map((r) => r.label), ['b', 'a', 'new'])
  })
})

describe('moveKey', () => {
  it('reorders and appends, and a new key is not required to be in the list', () => {
    assert.deepEqual(moveKey(['a', 'b', 'c'], 0, 3), ['b', 'c', 'a'])
    assert.deepEqual(moveKey(['a', 'b', 'c'], 2, 0), ['c', 'a', 'b'])
    assert.deepEqual(moveKey(['a', 'b', 'c'], 0, 1), ['a', 'b', 'c'])
    const rects = [{ top: 0, bottom: 10 }, { top: 10, bottom: 20 }, { top: 20, bottom: 30 }]
    assert.equal(dropIndex(rects, 1), 0)
    assert.equal(dropIndex(rects, 6), 1)
    assert.equal(dropIndex(rects, 16), 2)
    assert.equal(dropIndex(rects, 40), 3)
  })
})

describe('the menu sits on objects, not the tab rail', () => {
  const vue = src('src/components/ChannelSidebar.vue')
  const menu = src('src/components/SidebarRowMenu.vue')
  const icons = src('src/utils/uiIcons.ts')

  it('each list row has a menu and the icon rail does not', () => {
    const rail = vue.slice(vue.indexOf('class="sidebar-rail"'), vue.indexOf('class="sidebar-body"'))
    assert.doesNotMatch(rail, /SidebarRowMenu/)
    const self = vue.slice(vue.indexOf('data-testid="people-self"'), vue.indexOf('v-for="(p, peerIndex) in peers"'))
    assert.doesNotMatch(self, /SidebarRowMenu/)
    const markers = [
      'v-for="(p, peerIndex) in peers"',
      'v-for="(c, channelIndex) in channelRows"',
      'v-for="(row, topicIndex) in topicRows"',
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
    const ch = vue.indexOf('v-for="(c, channelIndex) in channelRows"')
    const th = vue.indexOf('v-for="(row, topicIndex) in topicRows"')
    assert.equal(vue.slice(ch, th).includes(':person="true"'), false)
  })

  it('the button is three lines and becomes an X while open', () => {
    assert.match(menu, /:name="open \? 'x' : 'menu'"/)
    assert.match(menu, /@click\.stop="emit\('toggle'\)"/)
    assert.match(menu, /aria-haspopup="menu"/)
    assert.match(icons, /menu: \["M4 6h16", "M4 12h16", "M4 18h16"\]/)
  })
})

describe('channel rows', () => {
  it('a channel menu includes mute and Properties, and a topic or person menu does not include Properties', () => {
    const channel = rowMenuItems(false, { channel: true, properties: true }).map((i) => i.id)
    assert.ok(channel.includes('mute'))
    assert.ok(channel.includes('properties'))
    assert.equal(rowMenuItems(false).some((i) => i.id === 'mute'), false)
    assert.equal(rowMenuItems(false).some((i) => i.id === 'properties'), false)
    assert.equal(rowMenuItems(true).some((i) => i.id === 'mute'), false)
    assert.equal(rowMenuItems(false, { person: true }).some((i) => i.id === 'properties'), false)
    assert.equal(rowMenuItems(false, { channel: true, muted: true }).find((i) => i.id === 'mute').labelKey, 'sidebar.row_menu.unmute')
    assert.equal(rowMenuItems(false, { channel: true }).some((i) => i.id === 'properties'), false)
    assert.equal(rowMenuItems(false, { channel: true, properties: true }).find((i) => i.id === 'properties').icon, 'settings')
  })

  it('right-click opens the same channel menu and a non-primary button does not drag', () => {
    const vue = src('src/components/ChannelSidebar.vue')
    assert.match(vue, /@contextmenu\.prevent="openChannelMenu\('ch:' \+ c\.channel_id\)"/)
    assert.match(vue, /@contextmenu\.prevent="openChannelMenu\('flow:ch:' \+ row\.id\)"/)
    assert.match(vue, /if \(e\.button !== 0\) return/)
    assert.equal(vue.split(':channel="true"').length - 1, 2)
    const topic = vue.slice(vue.indexOf('v-for="(row, topicIndex) in topicRows"'), vue.indexOf("row.kind === 'channel'"))
    assert.doesNotMatch(topic, /openChannelMenu/)
    assert.doesNotMatch(topic, /:channel="true"/)
  })
})

