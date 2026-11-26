// Spec 150 row B5: topicListView, the topic list's filter (New / All) and
// sort (Last update / Messages / Priority / Created; owner Q2 answer A, then
// SPL-6456 added Created).
// Cases C201-C206, C208, C210 of the spec's case table; each names its red
// control, a planted change in utils/topic-list-order.mjs that turns it red.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  TOPIC_LIST_FILTERS,
  TOPIC_LIST_SORTS,
  TOPIC_PRIORITY_DEFAULT,
  parseTopicListFilter,
  parseTopicListSort,
  pinEdge,
  topicListView,
  topicPriority,
  topicUnreadCount,
} from '../../src/utils/topic-list-order.mjs'
import { channelView } from '../../src/utils/channel-feed.mjs'
import { unreadFirst } from '../../src/utils/unread-first.mjs'
import { displayOrder } from '../../src/utils/view-prefs.mjs'

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
  // the owner, prd t1 0344254d msg f5ed1396: "radio buttons whith default 3" (SPL-4367)
  it('1 before 5; a topic with no priority sorts as 3, between a 2 and a 4 (red: no priority sorts first, or as 5)', () => {
    const rows = [card('none', at(9), 1, undefined), card('p5', at(8), 1, 5), card('p1', at(7), 1, 1), card('p4', at(6), 1, 4), card('p2', at(5), 1, 2)]
    assert.deepEqual(ids(topicListView(rows, { sort: 'priority' })), ['p1', 'p2', 'none', 'p4', 'p5'])
  })
  it('anything outside 1..5 is 3', () => {
    assert.equal(TOPIC_PRIORITY_DEFAULT, 3)
    for (const p of [undefined, null, '', 0, 6, 2.5, 'x', -1]) assert.equal(topicPriority(p), 3, String(p))
    assert.equal(topicPriority('2'), 2)
    const rows = [card('p4', at(9), 1, 4), card('zero', at(8), 1, 0)]
    assert.deepEqual(ids(topicListView(rows, { sort: 'priority' })), ['zero', 'p4'])
  })
  it('the sorts are Last update, Messages, Priority and Created (owner Q2 answer A, then SPL-6456)', () => {
    assert.deepEqual([...TOPIC_LIST_SORTS], ['last', 'messages', 'priority', 'created'])
  })
})

/* SPL-6456 (owner HUM-10, t1 a81e029c, msg 011b15dd): a topic card created at `made` (its own ts) */
function made(task, created, last, extra = {}) {
  return { ...card(task, last, 1, 3), ts: created, ...extra }
}

describe('SPL-6456 sort Created', () => {
  it('newest topic first, whatever its last update (red: keyOf ignores created)', () => {
    const rows = [made('old-busy', at(1), at(23)), made('new', at(9), at(9)), made('mid', at(5), at(6))]
    assert.deepEqual(ids(topicListView(rows, { sort: 'created' })), ['new', 'mid', 'old-busy'])
    assert.deepEqual(ids(topicListView(rows.slice().reverse(), { sort: 'created' })), ['new', 'mid', 'old-busy'])
  })
  it('received_at wins over ts, as the feed orders a message; createdOf overrides both', () => {
    const rows = [made('a', at(9), at(9), { received_at: at(2) }), made('b', at(4), at(4))]
    assert.deepEqual(ids(topicListView(rows, { sort: 'created' })), ['b', 'a'])
    assert.deepEqual(ids(topicListView(rows, { sort: 'created', createdOf: (r) => r.ts })), ['a', 'b'])
  })
  it('a hub topic row (feedRow: first_ts as ts) sorts by its first message, not its last', () => {
    const rows = [made('r1', at(3), at(20), { topic_row: true }), made('r2', at(8), at(8), { topic_row: true })]
    assert.deepEqual(ids(topicListView(rows, { sort: 'created' })), ['r2', 'r1'])
  })
  it('ties and unparsable times go by last update, then task_id (stable; red: drop the tie-break)', () => {
    const rows = [made('a', at(4), at(5)), made('c', at(4), at(9)), made('b', at(4), at(5)), made('x', 'not a time', at(1)), made('y', '', at(2))]
    assert.deepEqual(ids(topicListView(rows, { sort: 'created' })), ['c', 'b', 'a', 'y', 'x'])
    assert.deepEqual(ids(topicListView(rows.slice().reverse(), { sort: 'created' })), ['c', 'b', 'a', 'y', 'x'])
  })
  it('unread cards stay at the edge under Created (C208)', () => {
    const rows = [made('r-new', at(9), at(9)), made('u-old', at(1), at(2), { unread: 1 }), made('u-new', at(7), at(7), { unread: 2 })]
    assert.deepEqual(ids(topicListView(rows, { sort: 'created', unreadOf })), ['u-new', 'u-old', 'r-new'])
  })
  it('parses created; the older stored values parse as before', () => {
    assert.equal(parseTopicListSort('created'), 'created')
    for (const v of ['last', 'messages', 'priority']) assert.equal(parseTopicListSort(v), v)
    assert.equal(parseTopicListSort('Created'), 'last')
    assert.equal(parseTopicListSort(undefined), 'last')
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

// Spec 189 row B1 (owner HUM-10, t1 a48d75d6, D1..D4): pinEdge, the last step
// of the channel feed's drawn order (MessageFeed -> topicListView with `keep`,
// LiveFeed -> displayOrder -> unreadFirst -> pinEdge). Contracts C1..C4 of
// spec 189 section 7.1 on fixed rows, both message orders, 3 sorts x 2 filters.
// Red control (spec row B1): drop the pin step from `drawn` below and the
// fresh P3 card under Priority is not at index 0 (newest first) / last
// (newest last).
describe('spec 189 B1 the fresh card at the list edge', () => {
  /* read cards with more messages and a higher priority, two unread P1 cards, and
     my own new topic: newest, 1 message, the default priority 3, read (own) */
  const base = () => [
    card('mine', at(12), 1, undefined, 0),
    card('u-p1-a', at(11), 4, 1, 2),
    card('r-p1', at(10), 9, 1, 0),
    card('u-p1-b', at(9), 7, 1, 5),
    card('r-p2', at(8), 6, 2, 0),
    card('r-p5', at(7), 2, 5, 0),
  ]
  /* the feed's steps as MessageFeed and LiveFeed run them */
  function drawn(rows, { filter, sort, atEnd, fresh }) {
    const listed = topicListView(rows, { filter, sort, unreadOf, keep: fresh })
    const ordered = displayOrder(listed, atEnd ? 'newest-last' : 'newest-first')
    const edged = unreadFirst(ordered, unreadOf, { atEnd })
    return pinEdge(edged, fresh, { atEnd })
  }
  /* the same steps without the pin: the order every other card must keep (C2) */
  function today(rows, { filter, sort, atEnd }) {
    const listed = topicListView(rows, { filter, sort, unreadOf })
    return unreadFirst(displayOrder(listed, atEnd ? 'newest-last' : 'newest-first'), unreadOf, { atEnd })
  }
  for (const atEnd of [false, true]) {
    for (const sort of TOPIC_LIST_SORTS) {
      for (const filter of TOPIC_LIST_FILTERS) {
        const tag = `${atEnd ? 'newest last' : 'newest first'}, ${sort}, ${filter}`
        it(`C1 C2 C3 ${tag}: the fresh card sits at the edge, every other card keeps today's order`, () => {
          const out = ids(drawn(base(), { filter, sort, atEnd, fresh: ['mine'] }))
          assert.equal(atEnd ? out[out.length - 1] : out[0], 'mine', JSON.stringify(out))
          const rest = out.filter((id) => id !== 'mine')
          assert.deepEqual(rest, ids(today(base(), { filter, sort, atEnd })).filter((id) => id !== 'mine'))
          /* C1: the unread cards sit next to it, on the inner side */
          const inner = atEnd ? rest.slice(-2) : rest.slice(0, 2)
          assert.deepEqual([...inner].sort(), ['u-p1-a', 'u-p1-b'])
        })
      }
    }
  }
  it('C4 several fresh cards: the outer group in send order, the newest outermost', () => {
    const rows = [card('mine-2', at(13), 1, undefined, 0), ...base()]
    const fresh = ['mine', 'mine-2']
    for (const sort of TOPIC_LIST_SORTS) {
      const top = ids(drawn(rows, { filter: 'new', sort, atEnd: false, fresh }))
      assert.deepEqual(top.slice(0, 2), ['mine-2', 'mine'], sort)
      const bottom = ids(drawn(rows, { filter: 'new', sort, atEnd: true, fresh }))
      assert.deepEqual(bottom.slice(-2), ['mine', 'mine-2'], sort)
    }
  })
  it('C2 no fresh card: the very same array back; a fresh id not on screen changes nothing', () => {
    const rows = base()
    assert.equal(pinEdge(rows, []), rows)
    assert.equal(pinEdge(rows, null), rows)
    assert.equal(pinEdge(rows, ['gone']), rows)
    assert.equal(pinEdge(rows, ['']), rows)
  })
  it('C3 keep: New keeps a kept read card, and only that one', () => {
    const out = ids(topicListView(base(), { filter: 'new', unreadOf, keep: ['mine'] }))
    assert.deepEqual([...out].sort(), ['mine', 'u-p1-a', 'u-p1-b'])
    assert.deepEqual(ids(topicListView(base(), { filter: 'new', unreadOf })).sort(), ['u-p1-a', 'u-p1-b'])
  })
})

// SPL-6613 (owner HUM-10, t1 f7b53cf8, msg 5b8f9db2): the filter's title
// field. `only` = the task ids the hub's topic_select answer matched; the
// list keeps those cards alone, with New and the sort applied on top.
// Red on origin/master a464b5399: the option is ignored and every card stays.
describe('SPL-6613 title filter: only the ids the hub matched', () => {
  const rows = () => [card('a', at(9), 1, null, 1), card('b', at(8), 5, null), card('c', at(7), 2, null, 2), card('d', at(6), 9, null)]
  it('keeps only the cards named in `only`, in today\'s order', () => {
    assert.deepEqual(ids(topicListView(rows(), { only: new Set(['d', 'a']) })), ['a', 'd'])
  })
  it('an empty match keeps no card; null keeps every card', () => {
    assert.deepEqual(ids(topicListView(rows(), { only: new Set() })), [])
    assert.deepEqual(ids(topicListView(rows(), { only: null })), ['a', 'b', 'c', 'd'])
  })
  it('New and the sort apply on top; a kept (fresh) card outside the match goes', () => {
    assert.deepEqual(ids(topicListView(rows(), { only: new Set(['a', 'b', 'c']), filter: 'new', unreadOf, keep: ['b'] })), ['a', 'c', 'b'])
    assert.deepEqual(ids(topicListView(rows(), { only: new Set(['a', 'c']), filter: 'new', unreadOf, keep: ['d'] })), ['a', 'c'])
    assert.deepEqual(ids(topicListView(rows(), { only: new Set(['b', 'c', 'd']), sort: 'messages' })), ['d', 'b', 'c'])
  })
})
