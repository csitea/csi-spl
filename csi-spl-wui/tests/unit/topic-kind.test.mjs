// A topic list row's kind counts follow a kind set on one of its messages
// (the viewer store's list). Kind itself is set on the card (t1 e4bfddb1:
// the Topics view, whose rows had a Kind picker, is gone).
// Run: node tests/unit/topic-kind.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { rowMenuItems } from '../../src/utils/sidebar-row-menu.mjs'
import { importTs } from './lib/load-ts.mjs'

const { retargetKinds, topicsWithKind } = await importTs('src/utils/topic-kind.ts')

const root = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(root, rel), 'utf8')

const kinds = { task: 1, note: 2, result: 1 }

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
   (or by key) reaches the row's counts. */
describe('a kind set outside the row', () => {
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
})

describe('row menu', () => {
  it('no row offers Kind any more (the topic rows went)', () => {
    assert.equal(rowMenuItems(false, { topicKind: true }).some((i) => i.id === 'kind'), false)
    assert.equal(rowMenuItems(false, { person: true }).some((i) => i.id === 'kind'), false)
    assert.equal(rowMenuItems(false, { channel: true }).some((i) => i.id === 'kind'), false)
  })
})

describe('wiring', () => {
  /* t1 e4bfddb1: the Topics home (its rows, their badges and the row-menu
     Kind) is gone; Kind stays on the card's own badge and menu */
  it('the home page no longer lists topic rows with a Kind picker', () => {
    const home = src('src/pages/index.vue')
    assert.doesNotMatch(home, /topic-kind|maySetTopicKind|onKindClick|withSetKind/)
    assert.match(src('src/components/KindBadge.vue'), /async function setKind/)
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
  it('the row menu has no Kind branch left (no topic row to set it on)', () => {
    const menu = src('src/components/SidebarRowMenu.vue')
    assert.doesNotMatch(menu, /id === 'kind'|emit\('kind'\)/)
  })
})
