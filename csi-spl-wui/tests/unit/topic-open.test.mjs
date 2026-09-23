// CLE-3427 — which topic a clicked message opens, and the URL that reopens it.
//
// Owner (2026-09-20): "When being in a channel, for example in the lobby, If
// I click on a msg it should open in the 3rd left pannel the topic (even if
// there is not one for the msgs)".
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  isSelectedRow,
  queryWithTopic,
  sameQuery,
  sameTarget,
  targetFromQuery,
  topicPaneClickAction,
  topicQuery,
  topicTargetFor,
} from '../../src/utils/topic-open.mjs'

const LOBBY = '11111111-1111-4111-8111-111111111111'
const OTHER = '22222222-2222-4222-8222-222222222222'
const MSG = '33333333-3333-4333-8333-333333333333'

describe('topicTargetFor', () => {
  it('a row that is its own topic root opens that task (the old behaviour, kept)', () => {
    const t = topicTargetFor({ msg_id: OTHER, task_id: OTHER }, { currentTaskId: LOBBY })
    assert.deepEqual(t, { taskId: OTHER, mode: 'task', rootMsgId: OTHER, parentTaskId: '' })
  })

  it('a /channel or /dm row (no current task) opens its own task', () => {
    const t = topicTargetFor({ msg_id: OTHER, task_id: OTHER })
    assert.equal(t.mode, 'task')
    assert.equal(t.taskId, OTHER)
  })

  it('a lobby message — same task as the feed — opens a topic of its own', () => {
    const t = topicTargetFor({ msg_id: MSG, task_id: LOBBY }, { currentTaskId: LOBBY })
    assert.deepEqual(t, { taskId: MSG, mode: 'message', rootMsgId: MSG, parentTaskId: LOBBY })
  })

  it('opens even with no replies anywhere in sight — the row is all it needs', () => {
    /* the regression the owner asked for: nothing about a reply count decides this */
    const t = topicTargetFor({ msg_id: MSG, task_id: LOBBY, count: 0 }, { currentTaskId: LOBBY })
    assert.ok(t)
    assert.equal(t.taskId, MSG)
  })

  it('a row with no ids at all opens nothing', () => {
    assert.equal(topicTargetFor({}, { currentTaskId: LOBBY }), null)
    assert.equal(topicTargetFor(null), null)
  })

  it('a message-rooted reply is tagged with the task it was posted in, never with itself', () => {
    /* hub checkTags: parent_task_id must be a UUID other than task_id */
    const t = topicTargetFor({ msg_id: MSG, task_id: LOBBY }, { currentTaskId: LOBBY })
    assert.notEqual(t.parentTaskId, t.taskId)
  })
})

describe('the deep link', () => {
  it('a task-rooted topic is ?topic=<task>', () => {
    const t = topicTargetFor({ msg_id: OTHER, task_id: OTHER })
    assert.deepEqual(topicQuery(t), { topic: OTHER, in: undefined })
  })

  it('a message-rooted topic carries the task it lives in, so the root can be found again', () => {
    const t = topicTargetFor({ msg_id: MSG, task_id: LOBBY }, { currentTaskId: LOBBY })
    assert.deepEqual(topicQuery(t), { topic: MSG, in: LOBBY })
  })

  it('round-trips both modes', () => {
    for (const row of [{ msg_id: OTHER, task_id: OTHER }, { msg_id: MSG, task_id: LOBBY }]) {
      const t = topicTargetFor(row, { currentTaskId: LOBBY })
      assert.ok(sameTarget(targetFromQuery(topicQuery(t)), t), JSON.stringify(t))
    }
  })

  it('no ?topic= is no topic', () => {
    assert.equal(targetFromQuery({}), null)
    assert.equal(targetFromQuery({ q: 'hello' }), null)
    assert.equal(targetFromQuery(null), null)
  })

  it('takes the first value of a repeated parameter rather than "a,b"', () => {
    assert.equal(targetFromQuery({ topic: [OTHER, MSG] }).taskId, OTHER)
  })

  it('keeps the other query parameters and drops topic/in when the pane closes', () => {
    const t = topicTargetFor({ msg_id: MSG, task_id: LOBBY }, { currentTaskId: LOBBY })
    const opened = queryWithTopic({ q: 'from:CLE-07' }, t)
    assert.deepEqual(opened, { q: 'from:CLE-07', topic: MSG, in: LOBBY })
    assert.deepEqual(queryWithTopic(opened, null), { q: 'from:CLE-07' })
  })

  it('sameQuery ignores order and reads a repeated value as its first', () => {
    assert.equal(sameQuery({ a: '1', b: '2' }, { b: '2', a: '1' }), true)
    assert.equal(sameQuery({ a: '1' }, { a: ['1', '9'] }), true)
    assert.equal(sameQuery({ a: '1' }, { a: '2' }), false)
    assert.equal(sameQuery({ a: '1' }, { a: '1', b: undefined }), true)
  })
})

describe('the row the open topic is rooted at', () => {
  const msgRow = { msg_id: MSG, task_id: LOBBY }
  const rootRow = { msg_id: OTHER, task_id: OTHER }

  it('a message-rooted topic selects that one message, not its neighbours in the task', () => {
    const t = topicTargetFor(msgRow, { currentTaskId: LOBBY })
    assert.equal(isSelectedRow(msgRow, t), true)
    assert.equal(isSelectedRow({ msg_id: 'other-msg', task_id: LOBBY }, t), false)
  })

  it('a task-rooted topic selects every row of that task (the /channel card)', () => {
    const t = topicTargetFor(rootRow)
    assert.equal(isSelectedRow(rootRow, t), true)
    assert.equal(isSelectedRow(msgRow, t), false)
  })

  it('nothing is selected when no topic is open', () => {
    assert.equal(isSelectedRow(msgRow, null), false)
  })
})

describe('the pane click is wired to both topic panes', () => {
  const wui = join(dirname(fileURLToPath(import.meta.url)), '../..')
  const read = (rel) => readFileSync(join(wui, rel), 'utf8')

  it('clicking the pane selects it and the feed keeps the topic row selected', () => {
    for (const rel of ['src/components/TopicPane.vue', 'src/components/LiveTopicPane.vue']) {
      const src = read(rel)
      assert.match(src, /:class="\{ selected: topic\.paneSelected \}"/, rel)
      assert.match(src, /@click="onTopicPaneClick"/, rel)
      assert.match(src, /data-test="topic-heading"[^>]*aria-current="true"/, rel)
    }
    assert.match(read('src/composables/useTopicPaneClick.ts'), /topic\.selectPane\(\)/)
    assert.match(read('src/components/LiveFeed.vue'), /return Boolean\(props\.clickable\) && isSelectedRow\(m, topic\.target\)/)
    const store = read('src/stores/topic.ts')
    assert.match(store, /function selectPane\(\)/)
    assert.match(store, /paneSelected\.value = false/)
    assert.match(read('src/assets/css/main.css'), /\.topic\.selected/)
  })
})

describe('a click on the topic pane', () => {
  const el = (hit) => ({ closest: (sel) => (hit && String(sel).includes(hit) ? {} : null) })

  it('selects the pane, and the topic row that opened it stays selected', () => {
    assert.equal(topicPaneClickAction(null), 'pane')
    assert.equal(topicPaneClickAction(el('')), 'pane')
    assert.equal(topicPaneClickAction(el('article')), 'pane')
  })

  it('a control keeps its own job and leaves the selection alone', () => {
    for (const hit of ['button', 'textarea', 'role="button"']) {
      assert.equal(topicPaneClickAction(el(hit)), '', hit)
    }
  })

  it('selecting text in the pane is not a click that moves the selection', () => {
    assert.equal(topicPaneClickAction(el(''), { selecting: true }), '')
    assert.equal(topicPaneClickAction(null, { selecting: true }), '')
  })
})

describe('sameTarget', () => {
  it('separates the two modes on the same id', () => {
    const task = { taskId: MSG, mode: 'task', rootMsgId: '', parentTaskId: '' }
    const message = { taskId: MSG, mode: 'message', rootMsgId: MSG, parentTaskId: LOBBY }
    assert.equal(sameTarget(task, message), false)
    assert.equal(sameTarget(task, { ...task }), true)
    assert.equal(sameTarget(null, null), true)
    assert.equal(sameTarget(task, null), false)
  })
})
