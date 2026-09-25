// Right-click menu on a message: edit, copy link, delete.
// Run: node tests/unit/msg-menu.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { messageLink, msgMenuItems } from '../../src/utils/msg-menu.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const pathFor = (p) => '/fi' + p

describe('msgMenuItems', () => {
  it('offers edit, copy link, and delete on the author\'s own message', () => {
    assert.deepEqual(msgMenuItems({ editable: true }).map((i) => i.id), ['edit', 'copy', 'delete'])
    assert.deepEqual(msgMenuItems({ editable: true }).map((i) => i.icon), ['pencil', 'copy', 'trash'])
  })

  it('offers only copy link when the viewer cannot edit', () => {
    assert.deepEqual(msgMenuItems({ editable: false }).map((i) => i.id), ['copy'])
    assert.deepEqual(msgMenuItems().map((i) => i.id), ['copy'])
  })

  it('names each action from the catalogue', () => {
    for (const item of msgMenuItems({ editable: true })) {
      assert.match(item.labelKey, /^feed\.msg_menu\./)
    }
  })
})

describe('messageLink', () => {
  const msg = { task_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', msg_id: '11111111-1111-4111-8111-111111111111' }

  it('is the topic page with the message id as the hash', () => {
    assert.equal(messageLink(msg, pathFor), '/fi/t/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa#11111111-1111-4111-8111-111111111111')
  })

  it('uses parent_task_id when the row has no task of its own', () => {
    assert.equal(
      messageLink({ parent_task_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', msg_id: 'm2' }, (p) => p),
      '/t/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb#m2',
    )
  })

  it('is empty when the message names no topic', () => {
    assert.equal(messageLink({ msg_id: 'm' }, pathFor), '')
    assert.equal(messageLink(msg, null), '')
  })
})

describe('the card opens the menu on a right-click', () => {
  it('wires contextmenu to the same panel as a channel row', () => {
    const card = src('src/components/MessageCard.vue')
    const menu = src('src/components/MessageMenu.vue')
    assert.match(card, /@contextmenu="onContextMenu"/)
    assert.match(card, /<MessageMenu/)
    assert.match(menu, /role="menu"/)
    assert.match(menu, /<UiIcon :name="item\.icon"/)
    assert.match(menu, /\{\{ t\(item\.labelKey\) \}\}/)
    assert.match(menu, /data-testid="msg-menu"/)
  })
})

describe('every locale names the message actions', () => {
  it('translates edit and delete, and keeps the same keys', () => {
    const dir = join(WUI, 'i18n/locales')
    const en = JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8')).feed.msg_menu
    assert.deepEqual(Object.keys(en).sort(), ['copy_link', 'delete', 'edit', 'label'])
    const codes = readdirSync(dir).filter((f) => f.endsWith('.json') && f !== 'en.json').map((f) => f.replace(/\.json$/, ''))
    assert.ok(codes.length >= 18)
    for (const code of codes) {
      const row = JSON.parse(readFileSync(join(dir, code + '.json'), 'utf8')).feed.msg_menu
      assert.deepEqual(Object.keys(row).sort(), Object.keys(en).sort(), code)
      assert.notEqual(row.edit, en.edit, code)
      assert.notEqual(row.delete, en.delete, code)
      assert.notEqual(row.copy_link, en.copy_link, code)
    }
  })
})
