// Right-click menu on a message: edit, copy link, delete.
// Run: node tests/unit/msg-menu.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { joinBodies, messageLink, msgMenuItems, threadNeighbor } from '../../src/utils/msg-menu.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const pathFor = (p) => '/fi' + p

describe('msgMenuItems', () => {
  it('offers edit, copy link, and delete on the author\'s own message', () => {
    assert.deepEqual(msgMenuItems({ editable: true }).map((i) => i.id), ['edit', 'copy', 'delete'])
    assert.deepEqual(msgMenuItems({ editable: true }).map((i) => i.icon), ['pencil', 'copy', 'trash'])
  })

  it('adds merge with the previous or next message only when that neighbor exists', () => {
    const both = msgMenuItems({ editable: true, mergePrev: true, mergeNext: true }).map((i) => i.id)
    assert.deepEqual(both, ['edit', 'copy', 'merge-prev', 'merge-next', 'delete'])
    assert.deepEqual(msgMenuItems({ editable: true, mergePrev: true }).map((i) => i.id), ['edit', 'copy', 'merge-prev', 'delete'])
    assert.deepEqual(msgMenuItems({ editable: false, mergePrev: true, mergeNext: true }).map((i) => i.id), ['copy'])
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

describe('merging two messages in one thread', () => {
  const older = { msg_id: 'a', task_id: 't', ts: '2026-09-25T10:00:00Z', body: 'first' }
  const mid = { msg_id: 'b', task_id: 't', ts: '2026-09-25T10:01:00Z', body: 'second' }
  const newer = { msg_id: 'c', task_id: 't', ts: '2026-09-25T10:02:00Z', body: 'third' }
  const other = { msg_id: 'z', task_id: 'other', ts: '2026-09-25T10:00:30Z', body: 'elsewhere' }
  const rows = [newer, other, older, mid]

  it('previous is the older message in the same task, next is the newer one', () => {
    assert.equal(threadNeighbor(rows, mid, 'previous').msg_id, 'a')
    assert.equal(threadNeighbor(rows, mid, 'next').msg_id, 'c')
    assert.equal(threadNeighbor(rows, older, 'previous'), null)
    assert.equal(threadNeighbor(rows, newer, 'next'), null)
  })

  it('does not cross into another thread', () => {
    assert.equal(threadNeighbor(rows, other, 'previous'), null)
    assert.equal(threadNeighbor(rows, other, 'next'), null)
  })

  it('puts the older body first, with a blank line between', () => {
    assert.equal(joinBodies('first', 'second'), 'first\n\nsecond')
    assert.equal(joinBodies('first\n', '\nsecond'), 'first\n\nsecond')
    assert.equal(joinBodies('', 'second'), 'second')
    assert.equal(joinBodies('first', ''), 'first')
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
    assert.deepEqual(Object.keys(en).sort(), ['copy_link', 'delete', 'edit', 'label', 'merge_next', 'merge_prev'])
    const codes = readdirSync(dir).filter((f) => f.endsWith('.json') && f !== 'en.json').map((f) => f.replace(/\.json$/, ''))
    assert.ok(codes.length >= 18)
    for (const code of codes) {
      const row = JSON.parse(readFileSync(join(dir, code + '.json'), 'utf8')).feed.msg_menu
      assert.deepEqual(Object.keys(row).sort(), Object.keys(en).sort(), code)
      assert.notEqual(row.edit, en.edit, code)
      assert.notEqual(row.delete, en.delete, code)
      assert.notEqual(row.copy_link, en.copy_link, code)
      assert.notEqual(row.merge_prev, en.merge_prev, code)
      assert.notEqual(row.merge_next, en.merge_next, code)
    }
  })
})
