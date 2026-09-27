// SPL-986 (specs/041 §3.5): the card's Archive / Delete on a topic ROW - the
// left-rail Topics section, Flow and the Topics home. A row is a task; these
// decide which card the hub is asked about, what the row menu offers, and
// which rows a live frame removes.
// Run: node tests/unit/topic-row-archive.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  isRowTopic,
  rowCardCandidates,
  rowTopicState,
  topicFrameRows,
  withoutTopics,
} from '../../src/utils/topic-archive.mjs'
import { rowMenuItems } from '../../src/utils/sidebar-row-menu.mjs'
import { msgMenuItems } from '../../src/utils/msg-menu.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const LOBBY = 'lobby-task'

describe('which card a row is', () => {
  it('asks the first message first, then the task id (a lobby card thread)', () => {
    assert.deepEqual(rowCardCandidates('t1', { msg_id: 'm1' }, LOBBY), ['m1', 't1'])
    assert.deepEqual(rowCardCandidates('t1', null, LOBBY), ['t1'])
    assert.deepEqual(rowCardCandidates('t1', { msg_id: 't1' }, LOBBY), ['t1'])
  })
  it('never the lobby task itself, never an empty row', () => {
    assert.deepEqual(rowCardCandidates(LOBBY, { msg_id: 'm1' }, LOBBY), [])
    assert.deepEqual(rowCardCandidates('', { msg_id: 'm1' }, LOBBY), [])
  })
  it('a card opening the row task, or a lobby card whose thread is the row', () => {
    assert.equal(isRowTopic({ msg_id: 'm1', task_id: 't1' }, 't1', 'm1', LOBBY), true)
    assert.equal(isRowTopic({ msg_id: 't9', task_id: LOBBY }, 't9', 't9', LOBBY), true)
  })
  it('not a thread on a line of another topic: that topic\'s row owns the menu', () => {
    assert.equal(isRowTopic({ msg_id: 'c1', task_id: 'chan-task' }, 'c1', 'c1', LOBBY), false)
    assert.equal(isRowTopic({ msg_id: 'm1', task_id: LOBBY }, 't1', 'm1', LOBBY), false)
    assert.equal(isRowTopic(null, 't1', 'm1', LOBBY), false)
    assert.equal(isRowTopic({ msg_id: 't9', task_id: LOBBY }, 't9', 't9', ''), false, 'no lobby known: no lobby match')
  })
})

describe('what the row offers', () => {
  it('only what the hub answered, never a guess', () => {
    assert.deepEqual(rowTopicState(null, 'm1'), { state: 'none', msgId: '', canArchive: false, canDelete: false, replies: 0 })
    assert.deepEqual(rowTopicState({ msg_id: 'm1', replies: 3, can_archive: true, can_delete: true }, 'm1'),
      { state: 'ready', msgId: 'm1', canArchive: true, canDelete: true, replies: 3 })
    const member = rowTopicState({ msg_id: 'm1', replies: 3, can_archive: false, can_delete: false }, 'm1')
    assert.equal(member.canArchive || member.canDelete, false)
    assert.equal(rowTopicState({ can_archive: 'yes' }, 'm2').canArchive, false)
  })
  it('the row menu ends with the card menu\'s own Archive then Delete', () => {
    assert.deepEqual(rowMenuItems(false).map((i) => i.id), ['open', 'copy'])
    const items = rowMenuItems(false, { topicArchive: true, topicDelete: true })
    assert.deepEqual(items.map((i) => i.id), ['open', 'copy', 'archive', 'delete-topic'])
    const card = msgMenuItems({ topic: true }).slice(-2)
    assert.deepEqual(items.slice(-2).map((i) => [i.icon, i.labelKey]), card.map((i) => [i.icon, i.labelKey]))
    assert.deepEqual(rowMenuItems(false, { topicArchive: true }).map((i) => i.id), ['open', 'copy', 'archive'])
  })
})

describe('which rows a frame removes', () => {
  it('archive: the card task and its thread, never the lobby', () => {
    assert.deepEqual(topicFrameRows({ type: 'topic_archived', archived: true, msg_id: 'm1', task_id: 't1' }, LOBBY), ['t1', 'm1'])
    assert.deepEqual(topicFrameRows({ type: 'topic_archived', archived: true, msg_id: 'm2', task_id: LOBBY }, LOBBY), ['m2'])
    assert.deepEqual(topicFrameRows({ type: 'topic_archived', archived: false, msg_id: 'm1', task_id: 't1' }, LOBBY), [])
  })
  it('delete: every task it names', () => {
    assert.deepEqual(topicFrameRows({ type: 'topic_deleted', msg_id: 'm1', task_id: 't1', task_ids: ['t1', 's1'] }, LOBBY), ['t1', 'm1', 's1'])
    assert.deepEqual(topicFrameRows({ type: 'message', msg_id: 'm1' }, LOBBY), [])
  })
  it('withoutTopics keeps the rest in order', () => {
    const rows = [{ task_id: 'a' }, { task_id: 't1' }, { task_id: 'b' }]
    assert.deepEqual(withoutTopics(rows, ['t1']).map((r) => r.task_id), ['a', 'b'])
    assert.deepEqual(withoutTopics(null, ['t1']), [])
  })
})

describe('wiring', () => {
  it('the rail Topics and Flow rows and the Topics home open the menu by right-click and by the button', () => {
    const side = src('src/components/ChannelSidebar.vue')
    assert.match(side, /@contextmenu\.prevent="openTopicMenu\('th:' \+ row\.task_id, row\.task_id\)"/)
    assert.match(side, /@contextmenu\.prevent="openTopicMenu\('flow:th:' \+ row\.id, row\.id\)"/)
    assert.equal((side.match(/@delete-topic="askDeleteTopic\(/g) || []).length, 2)
    assert.match(side, /<LazyTopicDeleteDialog/)
    const home = src('src/pages/index.vue')
    assert.match(home, /@contextmenu\.prevent="openTopicMenu\(t\.task_id\)"/)
    assert.match(home, /@archive="archiveTopicRow\(t\.task_id\)"/)
    assert.match(home, /<LazyTopicDeleteDialog/)
  })
  it('the hub decides: the row asks GET …/topic before it offers anything', () => {
    const c = src('src/composables/useTopicRowActions.ts')
    assert.match(c, /api\.topicSize\(id\)/)
    assert.match(c, /isRowTopic\(size, task, id, lobby\)/)
    assert.match(c, /api\.archiveTopic\(row\.msgId, true\)/)
  })
  it('a live frame drops the row from the lists; the born cards get the card menu', () => {
    assert.match(src('src/layouts/default.vue'), /dropTopics\(topicFrameRows\(f, live\.lobbyTaskId\.value\)\)/)
    assert.match(src('src/components/BornTopics.vue'), /\n\s+topic-menu\n/)
  })
})
