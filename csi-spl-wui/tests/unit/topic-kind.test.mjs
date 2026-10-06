// Topics view: Kind is on the row menu only when the viewer may set the
// opener's kind, and the row's kind counts follow that one message.
// Run: node tests/unit/topic-kind.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { rowMenuItems } from '../../src/utils/sidebar-row-menu.mjs'
import { openerMessage, retargetKinds, topicRowKind } from '../../src/utils/topic-kind.mjs'

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
    assert.match(home, /retargetKinds/)
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
