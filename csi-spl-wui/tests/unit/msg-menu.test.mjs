// Right-click menu on a message: edit, copy link, delete.
// Run: node tests/unit/msg-menu.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { joinBodies, messageLink, msgMenuItems, threadLineLink, threadNeighbor, topicPaneLink } from '../../src/utils/msg-menu.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const pathFor = (p) => '/fi' + p

describe('msgMenuItems', () => {
  it('offers open, copy link, edit, and delete on the author\'s own message', () => {
    assert.deepEqual(msgMenuItems({ editable: true }).map((i) => i.id), ['open', 'copy', 'edit', 'delete'])
    assert.deepEqual(msgMenuItems({ editable: true }).map((i) => i.icon), ['open', 'copy', 'pencil', 'trash'])
  })

  it('adds merge with the previous or next message only when that neighbor exists', () => {
    const both = msgMenuItems({ editable: true, mergePrev: true, mergeNext: true }).map((i) => i.id)
    assert.deepEqual(both, ['open', 'copy', 'edit', 'merge-prev', 'merge-next', 'delete'])
    assert.deepEqual(msgMenuItems({ editable: true, mergePrev: true }).map((i) => i.id), ['open', 'copy', 'edit', 'merge-prev', 'delete'])
    assert.deepEqual(msgMenuItems({ editable: false, mergePrev: true, mergeNext: true }).map((i) => i.id), ['open', 'copy'])
  })
  it('714c7028: a topic card offers Merge into… beside Move to channel…', () => {
    assert.deepEqual(msgMenuItems({ moveChannel: true, mergeTopic: true, topic: true }).map((i) => i.id), ['open', 'copy', 'move-channel', 'merge-topic', 'archive', 'delete-topic'])
    assert.equal(msgMenuItems({ moveChannel: true }).map((i) => i.id).includes('merge-topic'), false, 'no merge entry without mergeTopic')
  })

  it('offers only open and copy link when the viewer cannot edit', () => {
    assert.deepEqual(msgMenuItems({ editable: false }).map((i) => i.id), ['open', 'copy'])
    assert.deepEqual(msgMenuItems().map((i) => i.id), ['open', 'copy'])
  })

  it('HUM-10 t1 7d9faaad: Hide from flow sits after Copy link only when hide is set', () => {
    const item = msgMenuItems({ hide: true }).find((i) => i.id === 'hide-flow')
    assert.deepEqual(item, { id: 'hide-flow', icon: 'eye-off', labelKey: 'feed.msg_menu.hide_flow' })
    assert.deepEqual(msgMenuItems({ hide: true }).map((i) => i.id), ['open', 'copy', 'hide-flow'])
    assert.equal(msgMenuItems({ editable: true }).some((i) => i.id === 'hide-flow'), false)
    assert.deepEqual(
      msgMenuItems({ hide: true, editable: true, touch: true }).map((i) => i.id),
      ['reply', 'react', 'open', 'copy-text', 'copy', 'hide-flow', 'edit', 'delete'],
    )
  })

  it('SPL-991: the phone sheet starts with Reply and Add emoji, adds Copy text and (when allowed) Kind; the desktop menu is unchanged', () => {
    assert.deepEqual(msgMenuItems({ editable: true, touch: true, kind: true }).map((i) => i.id), ['reply', 'react', 'open', 'copy-text', 'copy', 'edit', 'kind', 'delete'])
    assert.deepEqual(msgMenuItems({ touch: true }).map((i) => i.id), ['reply', 'react', 'open', 'copy-text', 'copy'])
    assert.deepEqual(msgMenuItems({ editable: true, kind: true }).map((i) => i.id), ['open', 'copy', 'edit', 'delete'])
    const topic = msgMenuItems({ editable: true, touch: true, topic: true }).map((i) => i.id)
    assert.deepEqual(topic.slice(-2), ['archive', 'delete-topic'])
  })

  it('t1 7a6be5a3: on the phone sheet Archive follows Edit, up from before Delete; Delete stays last; the desktop keeps Archive before Delete', () => {
    const all = { editable: true, kind: true, moveChannel: true, mergeTopic: true, topic: true }
    assert.deepEqual(msgMenuItems({ ...all, touch: true }).map((i) => i.id), ['reply', 'react', 'open', 'copy-text', 'copy', 'edit', 'archive', 'kind', 'move-channel', 'merge-topic', 'delete-topic'])
    assert.deepEqual(msgMenuItems(all).map((i) => i.id), ['open', 'copy', 'edit', 'move-channel', 'merge-topic', 'archive', 'delete-topic'])
    const locked = msgMenuItems({ touch: true, moveChannel: false, topicArchive: true, locks: { edit: 'e', move: 'm', merge: 'g', delete: 'd' } }).map((i) => i.id)
    assert.deepEqual(locked, ['reply', 'react', 'open', 'copy-text', 'copy', 'edit', 'archive', 'move-channel', 'merge-topic', 'delete-topic'])
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

describe('topicPaneLink', () => {
  const card = { task_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', msg_id: '11111111-1111-4111-8111-111111111111' }

  it('is this page with the card\'s topic open on the right', () => {
    assert.equal(
      topicPaneLink(card, { path: '/fi/channel/ops', query: { tenant: 'csi' } }),
      '/fi/channel/ops?tenant=csi&topic=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    )
  })

  it('replaces a topic already open in the URL', () => {
    assert.equal(
      topicPaneLink(card, { path: '/channel/ops', query: { topic: 'old', in: 'x' } }),
      '/channel/ops?topic=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    )
  })

  it('names the message and its task for a #lobby card', () => {
    assert.equal(
      topicPaneLink(card, { path: '/lobby', query: {}, currentTaskId: card.task_id }),
      '/lobby?topic=11111111-1111-4111-8111-111111111111&in=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    )
  })

  it('is empty without a page or an id', () => {
    assert.equal(topicPaneLink(card, {}), '')
    assert.equal(topicPaneLink({}, { path: '/lobby' }), '')
  })
})

describe('threadLineLink', () => {
  const line = { task_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', msg_id: 'm9' }

  it('keeps the open topic and adds the line as the hash', () => {
    assert.equal(
      threadLineLink(line, { path: '/dm/bob', query: { topic: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' } }),
      '/dm/bob?topic=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa#m9',
    )
  })

  it('falls back to the topic page when no topic is in the URL', () => {
    assert.equal(
      threadLineLink(line, { path: '/t/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', query: {}, pathFor: (p) => p }),
      '/t/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa#m9',
    )
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
    const menu = src('src/components/UiPointMenu.vue')
    assert.match(src('src/components/MessageMenu.vue'), /<UiPointMenu[\s\S]*testid="msg-menu"/)
    assert.match(card, /@contextmenu="onContextMenu"/)
    assert.match(card, /data-testid="msg-menu-btn"/)
    assert.match(card, /<LazyMessageMenu\s+v-if="menuOpen"/)
    assert.match(menu, /role="menu"/)
    assert.match(menu, /<UiIcon :name="item\.icon"/)
    assert.match(menu, /\{\{ t\(item\.labelKey\) \}\}/)
    assert.match(menu, /:data-testid="testid"/)
    assert.match(card, /@open="onMenuOpen"/)
    assert.match(card, /:hide="menuHide"/)
    assert.match(card, /@hide-flow="onMenuHide"/)
    assert.match(card, /function onMenuHide\(\) \{\n  closeMenu\(\)\n  swipeHideCommit\(\)\n\}/)
    assert.match(card, /const menuHide = computed\(\(\) => Boolean\(props\.msg\.msg_id\) && !props\.msg\.pending/)
    assert.match(card, /swipeLeftAction\(\{ swipeOn: true, starter: swipeStarter\.value/)
    assert.match(src('src/components/MessageMenu.vue'), /hide: props\.hide/)
    assert.match(src('src/components/MessageMenu.vue'), /id === 'hide-flow'/)
    assert.match(card, /topicPaneLink\(/)
    assert.match(card, /threadLineLink\(/)
  })
})

describe('every locale names the message actions', () => {
  it('translates edit and delete, and keeps the same keys', () => {
    const dir = join(WUI, 'i18n/locales')
    const en = JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8')).feed.msg_menu
    assert.equal(en.hide_flow, 'Hide from flow')
    assert.deepEqual(Object.keys(en).sort(), ['archive', 'copy_link', 'copy_text', 'delete', 'edit', 'hide_flow', 'kind', 'label', 'merge_next', 'merge_prev', 'merge_topic', 'move_channel', 'move_topic', 'open', 'open_in_channels', 'open_in_dm', 'open_parent', 'promote_topic', 'reply', 'unarchive', 'why'])
    const codes = readdirSync(dir).filter((f) => f.endsWith('.json') && f !== 'en.json').map((f) => f.replace(/\.json$/, ''))
    assert.ok(codes.length >= 18)
    for (const code of codes) {
      const row = JSON.parse(readFileSync(join(dir, code + '.json'), 'utf8')).feed.msg_menu
      assert.deepEqual(Object.keys(row).sort(), Object.keys(en).sort(), code)
      assert.notEqual(row.edit, en.edit, code)
      assert.notEqual(row.delete, en.delete, code)
      assert.notEqual(row.copy_link, en.copy_link, code)
      assert.notEqual(row.open, en.open, code)
      assert.notEqual(row.open_parent, en.open_parent, code)
      assert.notEqual(row.merge_prev, en.merge_prev, code)
      assert.notEqual(row.merge_next, en.merge_next, code)
      assert.notEqual(row.archive, en.archive, code) // SPL-983
      assert.notEqual(row.unarchive, en.unarchive, code)
      assert.notEqual(row.reply, en.reply, code) // SPL-991
      assert.notEqual(row.copy_text, en.copy_text, code)
      assert.notEqual(row.kind, en.kind, code)
      assert.notEqual(row.move_channel, en.move_channel, code) // SPL-1024
      assert.notEqual(row.move_topic, en.move_topic, code)
      assert.notEqual(row.merge_topic, en.merge_topic, code) // 714c7028
      assert.notEqual(row.hide_flow, en.hide_flow, code)
    }
  })
})
