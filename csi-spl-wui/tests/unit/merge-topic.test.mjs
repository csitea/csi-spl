// 714c7028: drag a topic card onto another topic = MERGE. The pure half:
// which card lights up for a topic drag, the frame normalizer, the merge
// applied to the stores on screen, and the topic-list / pane effects.
// Run: node tests/unit/merge-topic.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { isMergeCardDropTarget } from '../../src/utils/move.mjs'
import { mergeFrame, mergeFrameFromAnswer, applyMergeToStores, mergeErrorKey } from '../../src/utils/move-apply.mjs'
import { topicFrameRows, topicFrameTasks } from '../../src/utils/topic-archive.mjs'

const card = (o) => ({ msg_id: 'c2', task_id: 't2', is_parent: 1, channel: 'ops', ...o })
const topicDrag = { kind: 'topic', msgId: 'c1', taskId: 't1', topicTask: 't1', channel: 'devel', title: 'one' }

describe('isMergeCardDropTarget - which card takes a dragged topic', () => {
  it('another channel topic lights up', () => {
    assert.equal(isMergeCardDropTarget(topicDrag, card()), true)
  })
  it('a reply drag does not (that is a move, not a merge)', () => {
    assert.equal(isMergeCardDropTarget({ ...topicDrag, kind: 'message' }, card()), false)
  })
  it('the dragged topic itself, by task or by msg, is refused', () => {
    assert.equal(isMergeCardDropTarget(topicDrag, card({ task_id: 't1' })), false)
    assert.equal(isMergeCardDropTarget(topicDrag, card({ task_id: 'c1' })), false)
    assert.equal(isMergeCardDropTarget(topicDrag, card({ msg_id: 'c1' })), false)
  })
  it('a non-topic-card (a reply, a DM, the lobby) is refused', () => {
    assert.equal(isMergeCardDropTarget(topicDrag, card({ is_parent: 0 })), false)
    assert.equal(isMergeCardDropTarget(topicDrag, card({ channel: '' })), false)
    assert.equal(isMergeCardDropTarget(topicDrag, card({ channel: 'lobby' })), false)
    assert.equal(isMergeCardDropTarget(topicDrag, card({ task_id: 'lob' }), 'lob'), false)
  })
})

describe('mergeFrame - the normalizer', () => {
  it('a merge answer becomes a topic_merged frame; msg_ids includes the opener', () => {
    const f = mergeFrameFromAnswer({ kind: 'merge', msg_id: 'c1', task_id: 't2', from_task: 't1', channel: 'ops', from_channel: 'devel', msg_ids: ['r1'] })
    assert.equal(f.type, 'topic_merged')
    assert.deepEqual(f.msg_ids, ['c1', 'r1'])
    assert.equal(f.from_task, 't1')
    assert.equal(f.task_id, 't2')
  })
  it('an unmerge answer becomes a topic_unmerged frame; a move frame is not a merge', () => {
    assert.equal(mergeFrameFromAnswer({ kind: 'unmerge', msg_id: 'c1', task_id: 't1', msg_ids: [] }).type, 'topic_unmerged')
    assert.equal(mergeFrame({ type: 'topic_moved', msg_id: 'c1' }), null)
  })
})

describe('a merge applied to the stores on screen', () => {
  const merged = { type: 'topic_merged', msg_id: 'c1', task_id: 't2', from_task: 't1', channel: 'ops', from_channel: 'devel', msg_ids: ['c1', 'r1'] }
  it('the source card leaves the channel feed and the topics list; an open target pane re-reads', async () => {
    let caught = 0
    const channel = { active: 'ops', messages: [{ msg_id: 'c1', task_id: 't1', channel: 'devel' }, { msg_id: 'z', task_id: 'tz', channel: 'ops' }], catchUp: () => { caught++ } }
    const viewer = { topics: [{ task_id: 't1', channel: 'devel' }, { task_id: 't2', channel: 'ops' }] }
    const admitted = []
    const pane = { taskId: 't2', messages: [], drop: () => {}, admit: (rows) => admitted.push(...rows) }
    const f = applyMergeToStores(merged, { channel, viewer, pane, getTopic: async () => ({ messages: [{ msg_id: 'c1' }] }) })
    await new Promise((r) => setTimeout(r, 0))
    assert.equal(f.type, 'topic_merged')
    assert.deepEqual(channel.messages.map((m) => m.msg_id), ['z'], 'source card dropped')
    assert.deepEqual(viewer.topics.map((t) => t.task_id), ['t2'], 'source topic left the list')
    assert.equal(caught, 1, 'active channel re-read')
    assert.deepEqual(admitted.map((r) => r.msg_id), ['c1'], 'target pane re-read')
  })
  it('undo drops the un-merged rows from a pane on the target and re-reads the restored source; another frame is ignored', () => {
    const dropped = []
    const pane = { taskId: 't2', messages: [], drop: (id) => dropped.push(id), admit: () => {} }
    applyMergeToStores({ type: 'topic_unmerged', msg_id: 'c1', task_id: 't1', from_task: 't2', channel: 'devel', from_channel: 'ops', msg_ids: ['c1', 'r1'] }, { pane })
    assert.deepEqual(dropped, ['c1', 'r1'])
    assert.equal(applyMergeToStores({ type: 'topic_moved', msg_id: 'c1' }, { pane }), null, 'control: a move frame is not a merge')
  })
})

describe('mergeErrorKey - a merge failure names MERGE, and a missing endpoint is not silent', () => {
  it('a 404 with no hub token = the endpoint is not deployed yet', () => {
    assert.equal(mergeErrorKey({ status: 404 }), 'feed.merge.error_unavailable')
    assert.equal(mergeErrorKey(new Error('x')), 'feed.merge.error')
  })
  it('the hub tokens map to merge-specific keys', () => {
    assert.equal(mergeErrorKey({ status: 403, token: 'not_allowed' }), 'feed.merge.error_forbidden')
    assert.equal(mergeErrorKey({ status: 409, token: 'cycle' }), 'feed.merge.error_cycle')
    assert.equal(mergeErrorKey({ status: 404, token: 'not_found' }), 'feed.merge.error_not_found')
    assert.equal(mergeErrorKey({ status: 409, token: 'same_place' }), 'feed.merge.error_same_place')
  })
})

describe('the live-frame effects on the topic lists and panes', () => {
  const merged = { type: 'topic_merged', msg_id: 'c1', task_id: 't2', from_task: 't1', channel: 'ops', from_channel: 'devel', msg_ids: ['c1', 'r1'] }
  it('the merged-away source topic leaves the Topics / Flow lists', () => {
    assert.deepEqual(topicFrameRows(merged), ['t1'])
  })
  it('a pane open on the emptied source closes; the lobby never closes', () => {
    assert.deepEqual(topicFrameTasks(merged), ['t1'])
    assert.deepEqual(topicFrameTasks(merged, 't1'), [], 'the lobby task is never closed')
  })
})
