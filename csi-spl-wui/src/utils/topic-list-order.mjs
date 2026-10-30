/**
 * Spec 150 part 2 (row B5): the topic list's filter and sort, one pure
 * function. `channelView` keeps its job (the topic cards and `/search`);
 * the feed passes its rows through `topicListView` before drawing them.
 *
 * - Filter (panel D5): `all` keeps every card; `new` keeps the cards with
 *   unread messages, by the same count `unreadFirst` ranks by, so a card at
 *   the unread edge is always a card New keeps (case C210).
 * - Sort, owner poll Q2 answer A ("There is no third sort: three sorts are
 *   enough"): `last` (last update, today's order), `messages` (the topic's
 *   total count, more first), `priority` (1 first, 5 last; a topic nobody
 *   set is 3, between a 2 and a 4: spec 150 v1.1 D7). Ties go by last update, then `task_id`, so the
 *   order is stable (C206).
 * - Unread stays at the edge after any sort (panel D9, owner rule SPL-2506):
 *   the unread group comes first, the read group after it, each in the
 *   chosen sort (C208). Rows are newest first, as every store hands a feed
 *   its rows; `displayOrder` reverses what is drawn for newest last, which
 *   puts the unread group at the bottom edge.
 *
 * Pure, no Vue: unit-tested in tests/unit/topic-list-order.test.mjs.
 */
import { activityOf } from './feed.mjs'

export const TOPIC_LIST_FILTERS = Object.freeze(['all', 'new'])
export const TOPIC_LIST_SORTS = Object.freeze(['last', 'messages', 'priority'])
export const TOPIC_LIST_FILTER_DEFAULT = 'all'
export const TOPIC_LIST_SORT_DEFAULT = 'last'
/** a discussion nobody set: the owner's "default 3" (msg f5ed1396, spec 150 v1.1 D7, SPL-4367); issues keep 5 */
export const TOPIC_PRIORITY_DEFAULT = 3

/** @param {unknown} raw @returns {'all' | 'new'} */
export function parseTopicListFilter(raw) {
  const v = String(raw || '')
  return /** @type {'all' | 'new'} */ (TOPIC_LIST_FILTERS.includes(v) ? v : TOPIC_LIST_FILTER_DEFAULT)
}

/** @param {unknown} raw @returns {'last' | 'messages' | 'priority'} */
export function parseTopicListSort(raw) {
  const v = String(raw || '')
  return /** @type {'last' | 'messages' | 'priority'} */ (TOPIC_LIST_SORTS.includes(v) ? v : TOPIC_LIST_SORT_DEFAULT)
}

/**
 * A row's unread count as `unreadFirst` (utils/unread-first.mjs) reads it:
 * the whole part of a number, anything else 0. One rule for both, so New
 * and the unread edge never disagree on a card.
 * @param {unknown} n
 */
export function topicUnreadCount(n) {
  return Math.floor(Number(n)) || 0
}

/** 1..5; anything else (unset, out of range, not a whole number) is TOPIC_PRIORITY_DEFAULT */
export function topicPriority(p) {
  const n = Number(p)
  return p !== null && p !== '' && Number.isInteger(n) && n >= 1 && n <= 5 ? n : TOPIC_PRIORITY_DEFAULT
}

/** a topic's total message count; anything not a positive number is 0 */
function messageCount(n) {
  const c = Number(n)
  return Number.isFinite(c) && c > 0 ? c : 0
}

/** The sort key of a row: a number where a bigger one goes first. */
function keyOf(sort, row, countOf, priorityOf) {
  if (sort === 'messages') return messageCount(countOf(row))
  if (sort === 'priority') return -topicPriority(priorityOf(row))
  return 0
}

/**
 * @template T
 * @param {T[]} rows topic cards, newest activity first (channelView)
 * @param {{
 *   filter?: unknown,
 *   sort?: unknown,
 *   unreadOf?: (row: T) => number,
 *   countOf?: (row: T) => number,
 *   priorityOf?: (row: T) => number | null | undefined,
 *   lastOf?: (row: T) => string,
 * }} [opts]
 * @returns {T[]} a new array, unread group first, each group in the chosen sort
 */
export function topicListView(rows, opts = {}) {
  const list = Array.isArray(rows) ? rows : []
  const filter = parseTopicListFilter(opts.filter)
  const sort = parseTopicListSort(opts.sort)
  const unreadOf = typeof opts.unreadOf === 'function' ? opts.unreadOf : () => 0
  const countOf = typeof opts.countOf === 'function' ? opts.countOf : (r) => r && r.count
  const priorityOf = typeof opts.priorityOf === 'function' ? opts.priorityOf : (r) => r && r.priority
  const lastOf = typeof opts.lastOf === 'function' ? opts.lastOf : activityOf
  const items = list.map((row) => ({
    row,
    unread: topicUnreadCount(unreadOf(row)) > 0,
    k: keyOf(sort, row, countOf, priorityOf),
    last: String(lastOf(row) || ''),
    id: String((row && row.task_id) || ''),
  }))
  const kept = filter === 'new' ? items.filter((d) => d.unread) : items
  /* unread group first (the edge), then the chosen key, then last update, then task_id */
  kept.sort((a, b) => Number(b.unread) - Number(a.unread) || b.k - a.k || b.last.localeCompare(a.last) || b.id.localeCompare(a.id))
  return kept.map((d) => d.row)
}
