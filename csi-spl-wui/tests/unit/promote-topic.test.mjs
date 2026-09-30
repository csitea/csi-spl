// 8f588edd: drag a reply into the topics-list background = PROMOTE it into a
// new topic of its own. The pure half: which drag the topics zone takes, the
// "Make it a topic" menu entry, the frame normalizer, the promote applied to
// the stores on screen, and the error key.
// Run: node tests/unit/promote-topic.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { isPromoteDropTarget, mayPromoteMessage, movedNote } from '../../src/utils/move.mjs'
import { moveHit } from '../../src/utils/move-drag.mjs'
import { msgMenuItems } from '../../src/utils/msg-menu.mjs'
import { promoteFrame, promoteFrameFromAnswer, applyPromoteToStores, promoteErrorKey } from '../../src/utils/move-apply.mjs'

const reply = (o) => ({ msg_id: 'r1', task_id: 't1', is_parent: 0, channel: 'devel', from: 'HUM-1', ...o })
const me = { role: 'member', tenantOwner: false }

describe('isPromoteDropTarget - the topics-list background takes a reply drag', () => {
  it('a reply (message) drag lights it up', () => {
    assert.equal(isPromoteDropTarget({ kind: 'message', msgId: 'r1' }), true)
  })
  it('a topic drag does not (that is a move or a merge)', () => {
    assert.equal(isPromoteDropTarget({ kind: 'topic', msgId: 'c1' }), false)
    assert.equal(isPromoteDropTarget(null), false)
  })
})

describe('moveHit - a reply drag fits the topics zone; a topic drag does not', () => {
  const zone = (kind) => ({ closest: () => ({ dataset: { moveDrop: 'topics', moveId: 'promote', moveOk: 'true' } }) })
  it('a message drag over the topics zone is a hit', () => {
    const hit = moveHit(zone(), { kind: 'message' })
    assert.equal(hit && hit.kind, 'topics')
    assert.equal(hit && hit.ok, true)
  })
  it('a topic drag over the topics zone is not a hit', () => {
    assert.equal(moveHit(zone(), { kind: 'topic' }), null)
  })
})

describe('mayPromoteMessage / the menu entry', () => {
  it('the author may promote a reply, not a card', () => {
    assert.equal(mayPromoteMessage(reply(), 'HUM-1', me), true)
    assert.equal(mayPromoteMessage(reply({ is_parent: 1 }), 'HUM-1', me), false)
  })
  it('a member who is not the author may not', () => {
    assert.equal(mayPromoteMessage(reply(), 'HUM-2', me), false)
  })
  it('a DM or lobby reply may not be promoted', () => {
    assert.equal(mayPromoteMessage(reply({ channel: '' }), 'HUM-1', me), false)
    assert.equal(mayPromoteMessage(reply({ channel: 'lobby' }), 'HUM-1', me), false)
  })
  it('"Make it a topic" shows only when promoteTopic is set', () => {
    assert.ok(msgMenuItems({ promoteTopic: true }).some((i) => i.id === 'promote-topic'))
    assert.ok(!msgMenuItems({}).some((i) => i.id === 'promote-topic'))
  })
})

describe('promoteFrame - the normalizer', () => {
  it('a promote answer becomes a topic_promoted frame; msg_ids includes the message', () => {
    const f = promoteFrameFromAnswer({ kind: 'promote', msg_id: 'r1', task_id: 'tNEW', from_task: 't1', channel: 'devel', from_channel: 'devel', msg_ids: ['x1'] })
    assert.equal(f.type, 'topic_promoted')
    assert.deepEqual(f.msg_ids, ['r1', 'x1'])
    assert.equal(f.task_id, 'tNEW')
    assert.equal(f.from_task, 't1')
  })
  it('a demote answer becomes a topic_demoted frame; a move frame is not a promote', () => {
    assert.equal(promoteFrameFromAnswer({ kind: 'demote', msg_id: 'r1', task_id: 't1', msg_ids: [] }).type, 'topic_demoted')
    assert.equal(promoteFrame({ type: 'message_moved', msg_id: 'r1' }), null)
  })
})

describe('a promote applied to the stores on screen', () => {
  const promoted = { type: 'topic_promoted', msg_id: 'r1', task_id: 'tNEW', from_task: 't1', channel: 'devel', from_channel: 'devel', msg_ids: ['r1', 'x1'] }
  it('the source pane loses the promoted rows; the active channel re-reads', async () => {
    let caught = 0
    const channel = { active: 'devel', messages: [], catchUp: () => { caught++ } }
    const dropped = []
    const pane = { taskId: 't1', messages: [], drop: (id) => dropped.push(id), admit: () => {} }
    const f = applyPromoteToStores(promoted, { channel, pane })
    await new Promise((r) => setTimeout(r, 0))
    assert.equal(f.type, 'topic_promoted')
    assert.deepEqual(dropped, ['r1', 'x1'], 'the promoted rows left their old topic')
    assert.equal(caught, 1, 'the active channel re-read')
  })
  it('undo drops the new topic from the topics list and re-reads the restored source; a move frame is ignored', () => {
    const viewer = { topics: [{ task_id: 'tNEW' }, { task_id: 't2' }] }
    const admitted = []
    const pane = { taskId: 't1', messages: [], drop: () => {}, admit: (rows) => admitted.push(...rows), getTopic: async () => ({}) }
    const f = applyPromoteToStores({ type: 'topic_demoted', msg_id: 'r1', task_id: 't1', from_task: 'tNEW', channel: 'devel', from_channel: 'devel', msg_ids: ['r1', 'x1'] },
      { viewer, pane, getTopic: async () => ({ messages: [{ msg_id: 'r1' }] }) })
    assert.equal(f.type, 'topic_demoted')
    assert.deepEqual(viewer.topics.map((t) => t.task_id), ['t2'], 'the new topic left the list')
    assert.equal(applyPromoteToStores({ type: 'message_moved', msg_id: 'r1' }, { viewer }), null, 'control: a move frame is not a promote')
  })
})

describe('movedNote - a promoted card names its home topic', () => {
  it('a card with moved_from_task shows "moved from topic"', () => {
    assert.deepEqual(movedNote({ moved_at: 'now', moved_from_task: 't1', is_parent: 1, channel: 'devel' }), { kind: 'topic', task: 't1' })
  })
})

describe('promoteErrorKey - a promote failure reuses the move wording, endpoint absence is not silent', () => {
  it('a 404 with no hub token = the endpoint is not deployed yet', () => {
    assert.equal(promoteErrorKey({ status: 404 }), 'feed.merge.error_unavailable')
  })
  it('the hub tokens map to keys', () => {
    assert.equal(promoteErrorKey({ status: 403, token: 'not_allowed' }), 'feed.move.error_forbidden')
    assert.equal(promoteErrorKey({ status: 409, token: 'is_card' }), 'feed.move.error_is_card')
    assert.equal(promoteErrorKey(new Error('x')), 'feed.move.error')
  })
})
