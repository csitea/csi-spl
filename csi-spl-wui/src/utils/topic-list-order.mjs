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
 *   set is 3, between a 2 and a 4: spec 150 v1.1 D7), and, owner HUM-10
 *   (t1 a81e029c, msg 011b15dd: "add also the "created" attribute to the
 *   sorter drop down", SPL-6456), `created` (newest topic first, by its
 *   first message's time). Ties go by last update, then `task_id`, so the
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
export const TOPIC_LIST_SORTS = Object.freeze(['last', 'messages', 'priority', 'created'])
export const TOPIC_LIST_FILTER_DEFAULT = 'all'
export const TOPIC_LIST_SORT_DEFAULT = 'last'
/** a discussion nobody set: the owner's "default 3" (msg f5ed1396, spec 150 v1.1 D7, SPL-4367); issues keep 5 */
export const TOPIC_PRIORITY_DEFAULT = 3

/** @param {unknown} raw @returns {'all' | 'new'} */
export function parseTopicListFilter(raw) {
  const v = String(raw || '')
  return /** @type {'all' | 'new'} */ (TOPIC_LIST_FILTERS.includes(v) ? v : TOPIC_LIST_FILTER_DEFAULT)
}

/** @param {unknown} raw @returns {'last' | 'messages' | 'priority' | 'created'} */
export function parseTopicListSort(raw) {
  const v = String(raw || '')
  return /** @type {'last' | 'messages' | 'priority' | 'created'} */ (TOPIC_LIST_SORTS.includes(v) ? v : TOPIC_LIST_SORT_DEFAULT)
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

/**
 * When a topic was created: its card is the starter (the earliest message;
 * a hub topic row carries `first_ts` as `ts`), so its own moment. A time
 * that does not parse is 0, the oldest.
 */
function createdTime(t) {
  const ms = Date.parse(String(t || ''))
  return Number.isFinite(ms) ? ms : 0
}

/** The sort key of a row: a number where a bigger one goes first. */
function keyOf(sort, row, { countOf, priorityOf, createdOf }) {
  if (sort === 'messages') return messageCount(countOf(row))
  if (sort === 'priority') return -topicPriority(priorityOf(row))
  if (sort === 'created') return createdTime(createdOf(row))
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
 *   createdOf?: (row: T) => string,
 *   keep?: readonly string[],
 * }} [opts] keep: spec 189 D3, task ids New keeps although read (the fresh cards)
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
  const createdOf = typeof opts.createdOf === 'function' ? opts.createdOf : (r) => r && (r.received_at || r.ts)
  const items = list.map((row) => ({
    row,
    unread: topicUnreadCount(unreadOf(row)) > 0,
    k: keyOf(sort, row, { countOf, priorityOf, createdOf }),
    last: String(lastOf(row) || ''),
    id: String((row && row.task_id) || ''),
  }))
  const keep = new Set(Array.isArray(opts.keep) ? opts.keep.map(String) : [])
  const kept = filter === 'new' ? items.filter((d) => d.unread || keep.has(d.id)) : items
  /* unread group first (the edge), then the chosen key, then last update, then task_id */
  kept.sort((a, b) => Number(b.unread) - Number(a.unread) || b.k - a.k || b.last.localeCompare(a.last) || b.id.localeCompare(a.id))
  return kept.map((d) => d.row)
}

/**
 * Spec 189 row B1 (owner HUM-10, t1 a48d75d6, D1..D4): the topics the viewer
 * just created ("fresh", in send order) go to the very edge new posts go to,
 * whatever the sort, the filter and their priority (C1, C2). Run it LAST, on
 * the drawn rows, after `topicListView` and the unread edge (`unreadFirst`),
 * so nothing moves another card past them. Several fresh cards are the outer
 * group in send order, the newest outermost (C4). The other cards keep their
 * order, so a list with no fresh card comes back as it was.
 *
 * @template T
 * @param {T[]} rows the drawn rows (top first)
 * @param {readonly string[] | null | undefined} freshIds task ids, oldest send first
 * @param {{ atEnd?: boolean, idOf?: (row: T) => string }} [opts]
 *   atEnd: the edge is the bottom (newest last); idOf: a row's task id
 * @returns {T[]} a new array; `rows` when no row is fresh
 */
export function pinEdge(rows, freshIds, opts = {}) {
  const list = Array.isArray(rows) ? rows : []
  const rank = new Map((Array.isArray(freshIds) ? freshIds : []).map((id, i) => [String(id || ''), i]))
  rank.delete('')
  if (!rank.size) return list
  const idOf = typeof opts.idOf === 'function' ? opts.idOf : (r) => String((r && r.task_id) || '')
  const pinned = []
  const rest = []
  for (const row of list) {
    const i = rank.get(idOf(row))
    if (i === undefined) rest.push(row)
    else pinned.push({ row, i })
  }
  if (!pinned.length) return list
  /* the newest send outermost: first at the top, last at the bottom */
  pinned.sort((a, b) => (opts.atEnd ? a.i - b.i : b.i - a.i))
  const group = pinned.map((p) => p.row)
  return opts.atEnd ? [...rest, ...group] : [...group, ...rest]
}

/*
 * Spec 189 row B2 (owner HUM-10, t1 a48d75d6, answers OWN and RLD): the
 * topics the viewer created in this tab, per channel ("fresh"), which the
 * channel's topic list pins at its edge (`pinEdge` above).
 *
 * - D1 / C5: only the viewer's own send with no parent task, in a channel
 *   (not a DM), adds its task id. A reply, a DM, and a topic root from anyone
 *   else (live or on a loaded page) add none: no such event reaches `freshNote`.
 * - D2 / C6: the set ends when the open channel changes (`channel` to another
 *   name, or `leave` to a route off this channel) and on a reload (the state
 *   lives in memory only: no localStorage, no hub field). Opening a topic,
 *   a sort or a filter change and time do not end it.
 *
 * Unit-tested in tests/unit/fresh-topics.test.mjs; the tab's one copy lives
 * in composables/useFreshTopics.ts.
 *
 * @typedef {{ channel: string, ids: string[] }} FreshState  ids: oldest send first
 * @typedef {{ type: 'send', channel?: string | null, peer?: string | null, parentTaskId?: string | null, taskId?: string | null }
 *   | { type: 'channel', channel?: string | null }
 *   | { type: 'leave' }} FreshEvent
 */

/** @returns {FreshState} */
export function freshEmpty() {
  return { channel: '', ids: [] }
}

/**
 * @param {FreshState} state
 * @param {FreshEvent} ev
 * @returns {FreshState} the next state; `state` itself when nothing changes
 */
export function freshNote(state, ev) {
  const s = state && Array.isArray(state.ids) ? state : freshEmpty()
  if (!ev || typeof ev !== 'object') return s
  if (ev.type === 'leave') return s.ids.length || s.channel ? freshEmpty() : s
  const channel = String(ev.channel || '')
  if (ev.type === 'channel') return channel === s.channel ? s : { channel, ids: [] }
  if (ev.type !== 'send' || ev.parentTaskId || ev.peer || !channel) return s
  const id = String(ev.taskId || '')
  if (!id) return s
  const ids = channel === s.channel ? s.ids.filter((x) => x !== id) : []
  return { channel, ids: [...ids, id] }
}

/**
 * The fresh task ids of one channel, oldest send first; none for another
 * channel, a DM ('' / null) or an empty state.
 * @param {FreshState} state
 * @param {string | null | undefined} channel
 * @returns {string[]}
 */
export function freshIdsFor(state, channel) {
  const c = String(channel || '')
  return c && state && state.channel === c && Array.isArray(state.ids) ? state.ids : []
}

/**
 * D2: does a route change end the pin? It does unless the next route is this
 * channel's own feed (any query: ?topic= opens one of its topics) or a topic
 * page (`/t/<task_id>`).
 * @param {string} toPath the next route's path
 * @param {string | null | undefined} channel the channel the pin is for
 */
export function freshEndsOnRoute(toPath, channel) {
  const path = String(toPath || '').split(/[?#]/)[0].replace(/\/+$/, '')
  if (path.startsWith('/t/')) return false
  const c = String(channel || '')
  if (!c) return true
  let decoded
  try { decoded = decodeURIComponent(path) } catch { return true }
  return decoded !== `/channel/${c}`
}
