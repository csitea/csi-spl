// CLE-3427 — which thread a clicked message opens, and the URL that reopens it.
//
// Owner (2026-09-20): "When being in a channel, for example in the lobby, If
// I click on a msg it should open in the 3rd left pannel the thread (even if
// there is not one for the msgs)".
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  isSelectedRow,
  queryWithThread,
  sameQuery,
  sameTarget,
  targetFromQuery,
  threadQuery,
  threadTargetFor,
} from '../../src/utils/thread-open.mjs'

const LOBBY = '11111111-1111-4111-8111-111111111111'
const OTHER = '22222222-2222-4222-8222-222222222222'
const MSG = '33333333-3333-4333-8333-333333333333'

describe('threadTargetFor', () => {
  it('a row that is its own thread root opens that task (the old behaviour, kept)', () => {
    const t = threadTargetFor({ msg_id: OTHER, task_id: OTHER }, { currentTaskId: LOBBY })
    assert.deepEqual(t, { taskId: OTHER, mode: 'task', rootMsgId: OTHER, parentTaskId: '' })
  })

  it('a /channel or /dm row (no current task) opens its own task', () => {
    const t = threadTargetFor({ msg_id: OTHER, task_id: OTHER })
    assert.equal(t.mode, 'task')
    assert.equal(t.taskId, OTHER)
  })

  it('a lobby message — same task as the feed — opens a thread of its own', () => {
    const t = threadTargetFor({ msg_id: MSG, task_id: LOBBY }, { currentTaskId: LOBBY })
    assert.deepEqual(t, { taskId: MSG, mode: 'message', rootMsgId: MSG, parentTaskId: LOBBY })
  })

  it('opens even with no replies anywhere in sight — the row is all it needs', () => {
    /* the regression the owner asked for: nothing about a reply count decides this */
    const t = threadTargetFor({ msg_id: MSG, task_id: LOBBY, count: 0 }, { currentTaskId: LOBBY })
    assert.ok(t)
    assert.equal(t.taskId, MSG)
  })

  it('a row with no ids at all opens nothing', () => {
    assert.equal(threadTargetFor({}, { currentTaskId: LOBBY }), null)
    assert.equal(threadTargetFor(null), null)
  })

  it('a message-rooted reply is tagged with the task it was posted in, never with itself', () => {
    /* hub checkTags: parent_task_id must be a UUID other than task_id */
    const t = threadTargetFor({ msg_id: MSG, task_id: LOBBY }, { currentTaskId: LOBBY })
    assert.notEqual(t.parentTaskId, t.taskId)
  })
})

describe('the deep link', () => {
  it('a task-rooted thread is ?thread=<task>', () => {
    const t = threadTargetFor({ msg_id: OTHER, task_id: OTHER })
    assert.deepEqual(threadQuery(t), { thread: OTHER, in: undefined })
  })

  it('a message-rooted thread carries the task it lives in, so the root can be found again', () => {
    const t = threadTargetFor({ msg_id: MSG, task_id: LOBBY }, { currentTaskId: LOBBY })
    assert.deepEqual(threadQuery(t), { thread: MSG, in: LOBBY })
  })

  it('round-trips both modes', () => {
    for (const row of [{ msg_id: OTHER, task_id: OTHER }, { msg_id: MSG, task_id: LOBBY }]) {
      const t = threadTargetFor(row, { currentTaskId: LOBBY })
      assert.ok(sameTarget(targetFromQuery(threadQuery(t)), t), JSON.stringify(t))
    }
  })

  it('no ?thread= is no thread', () => {
    assert.equal(targetFromQuery({}), null)
    assert.equal(targetFromQuery({ q: 'hello' }), null)
    assert.equal(targetFromQuery(null), null)
  })

  it('takes the first value of a repeated parameter rather than "a,b"', () => {
    assert.equal(targetFromQuery({ thread: [OTHER, MSG] }).taskId, OTHER)
  })

  it('keeps the other query parameters and drops thread/in when the pane closes', () => {
    const t = threadTargetFor({ msg_id: MSG, task_id: LOBBY }, { currentTaskId: LOBBY })
    const opened = queryWithThread({ q: 'from:CLE-07' }, t)
    assert.deepEqual(opened, { q: 'from:CLE-07', thread: MSG, in: LOBBY })
    assert.deepEqual(queryWithThread(opened, null), { q: 'from:CLE-07' })
  })

  it('sameQuery ignores order and reads a repeated value as its first', () => {
    assert.equal(sameQuery({ a: '1', b: '2' }, { b: '2', a: '1' }), true)
    assert.equal(sameQuery({ a: '1' }, { a: ['1', '9'] }), true)
    assert.equal(sameQuery({ a: '1' }, { a: '2' }), false)
    assert.equal(sameQuery({ a: '1' }, { a: '1', b: undefined }), true)
  })
})

describe('the row the open thread is rooted at', () => {
  const msgRow = { msg_id: MSG, task_id: LOBBY }
  const rootRow = { msg_id: OTHER, task_id: OTHER }

  it('a message-rooted thread selects that one message, not its neighbours in the task', () => {
    const t = threadTargetFor(msgRow, { currentTaskId: LOBBY })
    assert.equal(isSelectedRow(msgRow, t), true)
    assert.equal(isSelectedRow({ msg_id: 'other-msg', task_id: LOBBY }, t), false)
  })

  it('a task-rooted thread selects every row of that task (the /channel card)', () => {
    const t = threadTargetFor(rootRow)
    assert.equal(isSelectedRow(rootRow, t), true)
    assert.equal(isSelectedRow(msgRow, t), false)
  })

  it('nothing is selected when no thread is open', () => {
    assert.equal(isSelectedRow(msgRow, null), false)
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
