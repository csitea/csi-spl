// CLE-77889 (owner, t1 99905c80): "even if I write some messages in the direct
// messages - those are shown to me as new ... they should be shown as new for
// the receiver of those msgs, but not me". The viewer's own row - their post
// from any box, or a line they typed at an agent's terminal (from=<agent>,
// typed_by=<viewer>), which the feed draws as theirs - is never new: not on
// the DM rail badge, not under the New-messages divider, not as an alert, and
// not as an unread reply on a topic card when it was sent from another tab or
// device. The receiver still sees it as new.
// Run: node tests/unit/own-message-unread.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { isViewersOwn } from '../../src/utils/typed-by.mjs'
import { unreadFromDms } from '../../src/utils/channel-feed.mjs'
import { countUnread, firstUnreadId, markTopicReadAt, ownReplyReadAt, replyTopicsOf, topicUnread, OWN_KEEP } from '../../src/utils/read-cursor.mjs'
import { escalateReason, shouldPing } from '../../src/utils/notify.mjs'

const ME = 'HUM-4'
const PEER = 'HUM-9'
const dm = (id, from, to, ts, extra = {}) => ({
  msg_id: id, task_id: `t-${id}`, from, from_box: from.startsWith('HUM') ? 'box-wui' : 'box-desk',
  to, to_box: to.startsWith('HUM') ? 'box-wui' : 'box-desk', channel: null, received_at: ts, ...extra,
})

describe('isViewersOwn', () => {
  it('own post, any box, either id shape', () => {
    assert.equal(isViewersOwn({ from: 'HUM-4' }, 'HUM-4'), true)
    assert.equal(isViewersOwn({ from: 'HUM-4@box-wui' }, 'HUM-4'), true)
    assert.equal(isViewersOwn({ from: 'HUM-4' }, 'HUM-4@box-wui'), true)
  })
  it('a line the viewer typed at an agent terminal is theirs', () => {
    assert.equal(isViewersOwn({ from: 'CLE-001', typed_by: 'HUM-4' }, 'HUM-4'), true)
  })
  it('someone else typing at the terminal, the agent itself, another member: not own', () => {
    assert.equal(isViewersOwn({ from: 'CLE-001', typed_by: 'HUM-17' }, 'HUM-4'), false)
    assert.equal(isViewersOwn({ from: 'CLE-001' }, 'HUM-4'), false)
    assert.equal(isViewersOwn({ from: 'HUM-40' }, 'HUM-4'), false)
    assert.equal(isViewersOwn({ from: 'CLE-001', typed_by: 'not-a-hum' }, 'not-a-hum'), false)
  })
  it('no viewer or no message: never own (fail closed to "new")', () => {
    assert.equal(isViewersOwn({ from: 'HUM-4' }, ''), false)
    assert.equal(isViewersOwn(null, 'HUM-4'), false)
  })
})

describe('DM rail unread (unreadFromDms)', () => {
  const topics = [{ count: 4, inline: { messages: [
    dm('a', ME, PEER, '2026-10-01T10:00:00Z'),
    dm('b', PEER, ME, '2026-10-01T10:01:00Z'),
    dm('c', ME, PEER, '2026-10-01T10:02:00Z'),
  ] } }, { count: 2, inline: { messages: [
    dm('d', 'CLE-001', ME, '2026-10-01T10:03:00Z', { typed_by: ME }),
    dm('e', 'CLE-001', ME, '2026-10-01T10:04:00Z'),
  ] } }]
  it('the sender: only the other end counts, never own lines nor own terminal lines', () => {
    assert.deepEqual(unreadFromDms(topics, {}, ME), { [`dm:${PEER}@box-wui`]: 1, 'dm:CLE-001@box-desk': 1 })
  })
  it('the receiver: the sender lines are new for them', () => {
    assert.deepEqual(unreadFromDms(topics.slice(0, 1), {}, PEER), { [`dm:${ME}@box-wui`]: 2 })
  })
  it('a self id carrying its box still excludes own lines', () => {
    assert.deepEqual(unreadFromDms(topics, {}, `${ME}@box-wui`)[`dm:${PEER}@box-wui`], 1)
  })
})

describe('New-messages divider and alerts', () => {
  const cursor = { ts: '2026-10-01T09:00:00Z', id: '' }
  const rows = [
    dm('x', 'CLE-001', ME, '2026-10-01T10:00:00Z', { typed_by: ME }),
    dm('y', ME, 'CLE-001', '2026-10-01T10:01:00Z'),
    dm('z', 'CLE-001', ME, '2026-10-01T10:02:00Z'),
  ]
  it('own and own-terminal rows are not under the divider nor counted', () => {
    assert.equal(firstUnreadId(rows, cursor, ME), 'z')
    assert.equal(countUnread(rows, cursor, ME), 1)
  })
  it('an own terminal line neither pings nor escalates for its author', () => {
    assert.equal(shouldPing(rows[0], { selfId: ME }), false)
    assert.equal(escalateReason(rows[0], { selfId: ME }), null)
    assert.equal(shouldPing(rows[0], { selfId: PEER }), true)
  })
})

describe('topic card: an own reply from another tab or device is seen', () => {
  const opened = { 't:T': { ts: '2026-10-01T10:00:00Z', id: '', count: 3 } }
  const reply = { msg_id: 'r1', task_id: 'T', from: ME, received_at: '2026-10-01T10:05:00Z' }
  it('moves the seen count by one, once per msg_id', () => {
    const a = ownReplyReadAt(opened, 'T', reply)
    assert.equal(a['t:T'].count, 4)
    assert.equal(topicUnread(4, a['t:T']), 0)
    assert.equal(ownReplyReadAt(a, 'T', reply), a)
  })
  it('the reply this tab sent (named at mark time) never counts twice', () => {
    const c = markTopicReadAt({}, 'T', 4, 'r1')
    assert.deepEqual(c['t:T'].own, ['r1'])
    assert.equal(ownReplyReadAt(c, 'T', reply), c)
    /* a later open keeps the own list */
    assert.deepEqual(markTopicReadAt(c, 'T', 6)['t:T'].own, ['r1'])
  })
  it('an own reply older than the cursor is already in the count', () => {
    const old = { ...reply, received_at: '2026-10-01T09:59:00Z' }
    assert.equal(ownReplyReadAt(opened, 'T', old), opened)
  })
  it('a topic never opened has no count to move (it shows a plain total)', () => {
    assert.deepEqual(ownReplyReadAt({}, 'T', reply), {})
  })
  it('the own list is bounded', () => {
    let c = markTopicReadAt({}, 'T', 0)
    for (let i = 0; i < OWN_KEEP + 5; i++) c = ownReplyReadAt(c, 'T', { msg_id: `m${i}`, received_at: '2999-01-01T00:00:00Z' })
    assert.equal(c['t:T'].own.length, OWN_KEEP)
    assert.equal(c['t:T'].count, OWN_KEEP + 5)
  })
  it('replyTopicsOf: the reply topic and its parent, never a topic row', () => {
    assert.deepEqual(replyTopicsOf({ task_id: 'T' }), ['T'])
    assert.deepEqual(replyTopicsOf({ task_id: 'C', parent_task_id: 'P' }), ['C', 'P'])
    assert.deepEqual(replyTopicsOf({ task_id: 'T', topic_row: true }), [])
  })
})
