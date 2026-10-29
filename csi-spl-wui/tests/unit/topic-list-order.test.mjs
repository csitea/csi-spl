// Spec 150 row B5: topicListView, the topic list's filter (New / All) and
// sort (Last update / Messages / Priority; owner Q2 answer A: no third sort).
// Cases C201-C206, C208, C210 of the spec's case table; each names its red
// control, a planted change in utils/topic-list-order.mjs that turns it red.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  TOPIC_LIST_SORTS,
  TOPIC_PRIORITY_DEFAULT,
  parseTopicListFilter,
  parseTopicListSort,
  topicListView,
  topicPriority,
  topicUnreadCount,
} from '../../src/utils/topic-list-order.mjs'
import { channelView } from '../../src/utils/channel-feed.mjs'
import { unreadFirst } from '../../src/utils/unread-first.mjs'

/* a topic card: task id, last update, total count, priority, unread */
function card(task, last, count, priority, unread = 0) {
  return { msg_id: `m-${task}`, task_id: task, ts: '2026-10-01T00:00:00Z', last_ts: last, count, priority, unread }
}
const at = (h) => `2026-10-29T${String(h).padStart(2, '0')}:00:00Z`
const ids = (rows) => rows.map((r) => r.task_id)
const unreadOf = (r) => r.unread

describe('C201 filter New', () => {
  it('keeps only the cards whose unreadOf is above 0 (red: the test always returns true)', () => {
    const rows = [card('a', at(9), 3, 5, 2), card('b', at(8), 1, 5, 0), card('c', at(7), 4, 5, 1)]
    assert.deepEqual(ids(topicListView(rows, { filter: 'new', unreadOf })), ['a', 'c'])
  })
  it('keeps nothing when no unreadOf is given', () => {
    assert.deepEqual(topicListView([card('a', at(9), 3, 5, 2)], { filter: 'new' }), [])
  })
})

describe('C202 filter All', () => {
  it('keeps every card in today\'s order (red: the New test applied under All)', () => {
    const rows = [card('a', at(9), 3, 5), card('b', at(8), 9, 1), card('c', at(7), 4, 2)]
    assert.deepEqual(ids(topicListView(rows, { filter: 'all', unreadOf })), ['a', 'b', 'c'])
    assert.deepEqual(ids(topicListView(rows)), ['a', 'b', 'c'], 'All and Last update are the defaults')
  })
  it('an unknown filter or sort reads as the default', () => {
    assert.equal(parseTopicListFilter('bogus'), 'all')
    assert.equal(parseTopicListSort('bogus'), 'last')
    assert.equal(parseTopicListFilter('new'), 'new')
  })
})

describe('C203 sort Last update', () => {
  it('equals channelView\'s order (red: sort by first_ts)', () => {
    /* `ts` (first post) runs the other way from `last_ts` (last update) */
    const msgs = [
      { msg_id: 'm1', task_id: 't1', ts: at(1), last_ts: at(5), body: 'x' },
      { msg_id: 'm2', task_id: 't2', ts: at(2), last_ts: at(9), body: 'x' },
      { msg_id: 'm3', task_id: 't3', ts: at(3), last_ts: at(4), body: 'x' },
      { msg_id: 'm4', task_id: 't4', ts: '2026-10-29T03:30:00Z', body: 'x' },
    ]
    const today = channelView(msgs).rows
    assert.deepEqual(ids(today), ['t2', 't1', 't3', 't4'])
    assert.deepEqual(ids(topicListView(today.slice().reverse(), { sort: 'last' })), ids(today))
  })
})

describe('C204 sort Messages', () => {
  it('higher count first, ties by last update (red: ascending sort)', () => {
    const rows = [card('a', at(9), 2, 5), card('b', at(8), 7, 5), card('c', at(7), 2, 5), card('d', at(6), 7, 5)]
    assert.deepEqual(ids(topicListView(rows, { sort: 'messages' })), ['b', 'd', 'a', 'c'])
  })
  it('reads countOf when given; a missing count is 0', () => {
    const rows = [card('a', at(9), undefined, 5), card('b', at(8), 1, 5)]
    assert.deepEqual(ids(topicListView(rows, { sort: 'messages' })), ['b', 'a'])
    assert.deepEqual(ids(topicListView(rows, { sort: 'messages', countOf: (r) => (r.task_id === 'a' ? 9 : 1) })), ['a', 'b'])
  })
})

describe('C205 sort Priority', () => {
  it('1 before 5; a topic with no priority sorts as 5 (red: no priority sorts first)', () => {
    const rows = [card('none', at(9), 1, undefined), card('p5', at(8), 1, 5), card('p1', at(7), 1, 1), card('p3', at(6), 1, 3)]
    assert.deepEqual(ids(topicListView(rows, { sort: 'priority' })), ['p1', 'p3', 'none', 'p5'])
  })
  it('anything outside 1..5 is 5', () => {
    for (const p of [undefined, null, '', 0, 6, 2.5, 'x', -1]) assert.equal(topicPriority(p), TOPIC_PRIORITY_DEFAULT, String(p))
    assert.equal(topicPriority('2'), 2)
    const rows = [card('zero', at(9), 1, 0), card('p4', at(8), 1, 4)]
    assert.deepEqual(ids(topicListView(rows, { sort: 'priority' })), ['p4', 'zero'])
  })
  it('there is no third sort (owner Q2 answer A)', () => {
    assert.deepEqual([...TOPIC_LIST_SORTS], ['last', 'messages', 'priority'])
  })
})

describe('C206 stable ties', () => {
  it('equal keys keep last-update order, then task_id (red: drop the tie-break)', () => {
    const rows = [card('a', at(5), 3, 2), card('c', at(9), 3, 2), card('b', at(5), 3, 2), card('d', at(7), 3, 2)]
    for (const sort of TOPIC_LIST_SORTS) {
      assert.deepEqual(ids(topicListView(rows, { sort })), ['c', 'd', 'b', 'a'], sort)
      assert.deepEqual(ids(topicListView(rows.slice().reverse(), { sort })), ['c', 'd', 'b', 'a'], `${sort}, input reversed`)
    }
  })
})

describe('C208 unread edge with a sort', () => {
  it('unread cards stay at the edge; each group in the chosen sort (red: apply the sort after the unread move)', () => {
    const rows = [
      card('r-p1', at(9), 9, 1, 0),
      card('u-p4', at(8), 2, 4, 3),
      card('r-p3', at(7), 5, 3, 0),
      card('u-p2', at(6), 8, 2, 1),
    ]
    assert.deepEqual(ids(topicListView(rows, { sort: 'priority', unreadOf })), ['u-p2', 'u-p4', 'r-p1', 'r-p3'])
    assert.deepEqual(ids(topicListView(rows, { sort: 'messages', unreadOf })), ['u-p2', 'u-p4', 'r-p1', 'r-p3'])
    assert.deepEqual(ids(topicListView(rows, { sort: 'last', unreadOf })), ['u-p4', 'u-p2', 'r-p1', 'r-p3'])
  })
})

describe('C210 New and the unread edge agree', () => {
  it('every card unreadFirst puts at the edge is kept by New, and no other (red: a truthy unread test)', () => {
    /* counts unreadFirst floors: 0.5 and '0.9' are not unread, '2' and 1.5 are */
    const odd = [0, 0.5, '0.9', '2', 1.5, NaN, -1, null, undefined, 'x', 3]
    const rows = odd.map((u, i) => card(`t${i}`, at(20 - i), 1, 5, u))
    /* a card is at the edge when unreadFirst moves it above a read card listed before it */
    const read = card('read', at(23), 1, 5, 0)
    const edge = new Set(rows.filter((r) => unreadFirst([read, r], unreadOf)[0] === r).map((r) => r.task_id))
    const kept = new Set(ids(topicListView(rows, { filter: 'new', unreadOf })))
    assert.deepEqual([...kept].sort(), [...edge].sort())
    assert.deepEqual([...kept].sort(), ['t10', 't3', 't4'])
    assert.deepEqual(odd.map(topicUnreadCount), [0, 0, 0, 2, 1, 0, -1, 0, 0, 0, 3])
  })
})
