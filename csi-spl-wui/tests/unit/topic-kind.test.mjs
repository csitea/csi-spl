// Topics view: Kind is on the row menu only when the viewer may set the
// opener's kind, and the row's kind counts follow that one message.
// Run: node tests/unit/topic-kind.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { rowMenuItems } from '../../src/utils/sidebar-row-menu.mjs'
import { openerMessage, retargetKinds, topicRowKind, topicsWithKind, withSetKind } from '../../src/utils/topic-kind.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(root, rel), 'utf8')

const opener = { msg_id: 'm1', from: 'HUM-1', kind: 'task' }
const kinds = { task: 1, note: 2, result: 1 }

describe('topicRowKind', () => {
  it('the author may set the opener key, and only that key', () => {
    assert.equal(topicRowKind(opener, 'HUM-1', null, kinds), 'task')
    assert.equal(topicRowKind(opener, 'GRK-03', null, kinds), '')
    assert.equal(topicRowKind(opener, 'GRK-03', 'admin', kinds), 'task')
    assert.equal(topicRowKind({ ...opener, pending: true }, 'HUM-1', 'admin', kinds), '')
    assert.equal(topicRowKind({ ...opener, kind: 'msg' }, 'HUM-1', null, kinds), '')
    assert.equal(topicRowKind(null, 'HUM-1', 'admin', kinds), '')
  })
  it('a post with no kind is a note', () => {
    assert.equal(topicRowKind({ msg_id: 'm2', from: 'HUM-1', kind: '' }, 'HUM-1', null, { note: 1 }), 'note')
  })
})

describe('openerMessage', () => {
  it('skips a reply and returns the oldest card', () => {
    const rows = [
      { msg_id: 'r1', is_parent: 0, kind: 'note' },
      { msg_id: 'c1', kind: 'task' },
      { msg_id: 'c2', kind: 'result' },
    ]
    assert.equal(openerMessage(rows, '').msg_id, 'c1')
    assert.equal(openerMessage([], ''), null)
    assert.equal(openerMessage([{ msg_id: 'r1', is_parent: 0 }], ''), null)
  })
})

describe('retargetKinds', () => {
  it('moves one count, drops a zero, and the swap is the rollback', () => {
    const next = retargetKinds(kinds, 'task', 'blocker')
    assert.deepEqual(next, { note: 2, result: 1, blocker: 1 })
    assert.equal(Object.hasOwn(next, 'task'), false)
    assert.deepEqual(retargetKinds(next, 'blocker', 'task'), { note: 2, result: 1, task: 1 })
    assert.deepEqual(retargetKinds({ note: 2 }, 'note', 'task'), { note: 1, task: 1 })
    assert.deepEqual(retargetKinds({ note: 2 }, 'note', 'note'), { note: 2 })
    assert.deepEqual(retargetKinds(null, '', 'task'), {})
  })
})

/* HUM-10 (t1 9e969f63): the opener's kind set from the open topic's card
   (or by key) reaches the row - its counts, and the opener it holds. */
describe('a kind set outside the row', () => {
  const blockerOpener = { msg_id: 'm1', from: 'HUM-1', kind: 'blocker', task_id: 'T1' }
  it('the row drops its last blocker and the swap is the rollback', () => {
    const topics = [{ task_id: 'T1', kinds: { blocker: 1, note: 2 } }, { task_id: 'T2', kinds: { blocker: 1 } }]
    const next = topicsWithKind(topics, 'T1', 'blocker', 'note')
    assert.deepEqual(next[0].kinds, { note: 3 })
    assert.equal(next[1], topics[1], 'another topic keeps its row')
    assert.deepEqual(topicsWithKind(next, 'T1', 'note', 'blocker')[0].kinds, { note: 2, blocker: 1 })
    assert.deepEqual(topicsWithKind(topics, 'T1', '', 'note')[0].kinds, { blocker: 1, note: 2 }, 'no kind is a note')
    assert.equal(topicsWithKind(topics, 'T9', 'blocker', 'note'), topics, 'a topic not listed changes nothing')
    assert.equal(topicsWithKind(topics, 'T1', 'note', 'note'), topics)
  })
  it('the held opener reads the new kind, so the row badge stays its button', () => {
    const kinds = { note: 3 }
    /* control: the opener as read before the change no longer matches a key */
    assert.equal(topicRowKind(blockerOpener, 'HUM-1', null, kinds), '')
    const held = withSetKind(blockerOpener, { m1: 'note' })
    assert.equal(held.kind, 'note')
    assert.equal(blockerOpener.kind, 'blocker', 'the held copy is not mutated')
    assert.equal(topicRowKind(held, 'HUM-1', null, kinds), 'note')
    assert.equal(withSetKind(blockerOpener, {}), blockerOpener)
    assert.equal(withSetKind(null, { m1: 'note' }), null)
  })
  it('opener not read yet: nothing is settable until the click has read it', () => {
    assert.equal(topicRowKind(withSetKind(null, { m1: 'note' }), 'HUM-1', 'admin', { blocker: 1 }), '')
    assert.equal(topicRowKind(blockerOpener, 'HUM-1', null, { blocker: 1 }), 'blocker')
    assert.equal(topicRowKind(blockerOpener, 'GRK-03', 'biz_owner', { blocker: 1 }), 'blocker')
  })
})

describe('row menu', () => {
  it('Kind is there only when the caller already knows the viewer may', () => {
    assert.deepEqual(
      rowMenuItems(false, { topicArchive: true, topicDelete: true }).map((i) => i.id),
      ['open', 'copy', 'archive', 'delete-topic'],
    )
    const items = rowMenuItems(false, { topicKind: true, topicArchive: true, topicDelete: true })
    assert.deepEqual(items.map((i) => i.id), ['open', 'copy', 'kind', 'archive', 'delete-topic'])
    const kind = items.find((i) => i.id === 'kind')
    assert.equal(kind.icon, 'tag')
    assert.equal(kind.labelKey, 'feed.msg_menu.kind')
    assert.deepEqual(rowMenuItems(true, { topicKind: true }).map((i) => i.id), ['open', 'copy', 'read', 'kind'])
    assert.equal(rowMenuItems(false).some((i) => i.id === 'kind'), false)
    assert.equal(rowMenuItems(false, { person: true }).some((i) => i.id === 'kind'), false)
    assert.equal(rowMenuItems(false, { channel: true }).some((i) => i.id === 'kind'), false)
  })
})

describe('wiring', () => {
  it('the topics home offers Kind from the badge and from the row menu', () => {
    const home = src('src/pages/index.vue')
    assert.match(home, /:topic-kind="maySetTopicKind\(t\)"/)
    assert.match(home, /@kind="openTopicKind\(t\.task_id\)"/)
    assert.match(home, /data-topic-kind/)
    assert.match(home, /withSetKind\(held, viewer\.kindSet\)/)
  })
  it('a row badge click reads the opener first, then opens the picker', () => {
    const home = src('src/pages/index.vue')
    const body = home.slice(home.indexOf('async function onKindClick'))
    const read = body.indexOf('await ensureOpener(t.task_id)')
    const tick = body.indexOf('await nextTick()')
    const click = body.indexOf('btn.click()')
    assert.ok(read >= 0 && read < tick && tick < click, 'read, render, then click the badge button')
  })
  it('every kind setter moves the row counts through one store call', () => {
    const badge = src('src/components/KindBadge.vue')
    const keys = src('src/components/KindKeyHost.vue')
    const edit = src('src/composables/useMessageEdit.ts')
    const viewer = src('src/stores/viewer.ts')
    assert.match(badge, /edit\.applyKind\(from, row, m\)/)
    assert.match(keys, /edit\.applyKind\(from, row\)/)
    assert.match(edit, /useViewerStore\(\)\.setKind\(/)
    assert.match(viewer, /topicsWithKind\(topics\.value, taskId, from, to\)/)
    const body = badge.slice(badge.indexOf('async function setKind'))
    assert.ok(body.indexOf("emit('applied'") < body.indexOf('edit.applyKind'), 'the row hears applied before its badge can unmount')
  })
  it('the badge tells the row before the hub call, and takes it back on a refusal', () => {
    const badge = src('src/components/KindBadge.vue')
    const body = badge.slice(badge.indexOf('async function setKind'))
    const pending = body.indexOf("emit('pending'")
    const call = body.indexOf('setMessageKind')
    const clear = body.indexOf("pending.value = ''")
    const revert = body.indexOf("emit('revert'")
    assert.ok(pending > 0 && pending < call, 'pending emit is before the hub call')
    assert.ok(clear > call && clear < revert, 'a refusal clears the glyph, then tells the row')
    assert.match(badge, /const edit = useMessageEdit\(\)/)
    assert.doesNotMatch(badge, /props\.msg \? useMessageEdit/)
  })
  it('the row menu emits kind, and does not treat it as Open', () => {
    const menu = src('src/components/SidebarRowMenu.vue')
    assert.match(menu, /else if \(id === 'kind'\) \{\s+emit\('kind'\)/)
  })
})
