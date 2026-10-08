import { dmPeerOf } from './channel-feed.mjs'
import { topicQuery } from './topic-open.mjs'

/**
 * (SPL-15): "Open parent section" on a thread message.
 *
 * Owner, 2026-09-26: from a search result, a thread message's right-click
 * menu opens the place the thread lives in: the parent message selected in
 * the middle, the channel or DM tab selected on the left, and the thread
 * still open on the right.
 *
 * That place is the channel (/channel/<id>) or the DM (/dm/<peer>) the
 * message belongs to, with the open topic kept in ?topic= / ?in= (so the
 * parent card is the selected one) and the message itself as the hash (so
 * the thread pane scrolls to it). An issue's discussion is a topic in the
 * reserved `issues` id that the channel list never shows (spec 039 §3.4,
 * SPL-68 - it was #tasks until that channel was removed); its parent
 * section is the Issues tab with that issue selected.
 */

/** The channel id an issue's discussion lives in (hub store.ChannelIssues). */
export const ISSUE_CHANNEL = 'issues'

/** Where issue discussions lived before rdb 0050 moved them (hub store.ChannelTasks). */
const RETIRED_ISSUE_CHANNEL = 'tasks'

/** A message's channel id, without a leading '#'. '' for a DM. */
export function parentChannelOf(msg) {
  const m = msg && typeof msg === 'object' ? msg : {}
  return String(m.channel || '').trim().replace(/^#/, '')
}

/** The topic a thread message belongs to: the reply's parent, else its own task. */
export function parentTopicOf(msg) {
  const m = msg && typeof msg === 'object' ? msg : {}
  return String(m.parent_task_id || m.task_id || '')
}

/**
 * Could this message be an issue's discussion? Only the issue channel
 * carries them (and the retired #tasks, until rdb 0050 has moved its rows);
 * the caller asks the hub which issue, if any, owns the topic.
 */
export function mayBeIssueTopic(msg) {
  const ch = parentChannelOf(msg).toLowerCase()
  return ch === ISSUE_CHANNEL || ch === RETIRED_ISSUE_CHANNEL
}

/** Is `target` the open topic this message is shown in? */
function holdsMessage(target, m) {
  if (!target || typeof target !== 'object' || !target.taskId) return false
  const id = String(target.taskId)
  return String(m.task_id || '') === id
    || String(m.parent_task_id || '') === id
    || String(m.msg_id || '') === id
}

/**
 * Is this message the one that opens its topic (a level-1 row, not a reply)?
 * HUM-10 (topic c15b557e): such a card's jump stops at the topic level - the
 * channel or DM selected, the card selected, the topic NOT opened.
 */
export function isTopicStarter(msg) {
  const m = msg && typeof msg === 'object' ? msg : {}
  return !m.parent_task_id && m.is_parent !== 0
}

/**
 * Which place the menu item names for this message (HUM-10, topic c15b557e):
 * 'dm' - "Open in direct msg view"; 'channel' - "Open in channels view";
 * 'issue' - an issue discussion, whose place is the Issues tab, keeps "Open
 * parent section"; '' - no place (no item). MessageCard computes the same
 * inline (this module stays out of the initial chunk, specs/027).
 *
 * @param {unknown} msg
 * @param {string} [self] the viewer's id
 * @returns {'dm' | 'channel' | 'issue' | ''}
 */
export function parentKindOf(msg, self = '') {
  const m = msg && typeof msg === 'object' ? msg : {}
  if (parentChannelOf(m)) return mayBeIssueTopic(m) ? 'issue' : 'channel'
  return dmPeerOf(m, String(self || '')) ? 'dm' : ''
}

/**
 * How far the feed must scroll so the card sits at the reader's edge: the
 * TOP of the list when they read newest first (prepend), the BOTTOM when
 * newest last (append) - the edge where new cards arrive.
 *
 * @param {{ top: number, bottom: number }} card the card's client rect
 * @param {{ top: number, bottom: number }} scroller the feed's client rect
 * @param {boolean} newestLast the person's "Message order" is newest last
 * @param {number} [padBottom] the scroller's bottom padding (the docked Omnibox sits over it)
 * @returns {number} the scrollTop delta
 */
export function cardScrollDelta(card, scroller, newestLast, padBottom = 0) {
  if (newestLast) return card.bottom - (scroller.bottom - (Number(padBottom) || 0))
  return card.top - scroller.top
}

/**
 * The location that moves only the hash. A bare `{ hash }` is relative to the
 * current path but drops its query, and with it the ?topic= of the thread
 * just opened (open-in-place case 12: #alerts, then a #lobby reply from Flow).
 *
 * @param {{ query?: Record<string, unknown> } | null | undefined} current the current route
 * @param {string} hash
 * @returns {{ query: Record<string, unknown>, hash: string }}
 */
export function hashOnlyLocation(current, hash) {
  return { query: { ...((current && current.query) || {}) }, hash: String(hash || '') }
}

/**
 * Where "Open parent section" goes, or null when the message names no
 * channel and no other DM end (a broadcast, a row with no ids).
 *
 * @param {unknown} msg the thread message
 * @param {{ self?: string, target?: { taskId?: string, mode?: string, parentTaskId?: string } | null, issueKey?: string, topicLevel?: boolean }} [opts]
 *   self: the viewer's id (the DM end that is not the peer);
 *   target: the topic open on the right, kept as it is when it holds this message;
 *   issueKey: the issue whose discussion this topic is, when there is one;
 *   topicLevel: a topic message (isTopicStarter) opens nothing - the card menu's rule
 * @returns {{ path: string, query: Record<string, string>, hash: string, kind: 'channel' | 'dm' | 'issue' } | null}
 */
export function parentSection(msg, opts = {}) {
  const o = opts && typeof opts === 'object' ? opts : {}
  const m = msg && typeof msg === 'object' ? msg : {}
  const key = String(o.issueKey || '').trim()
  if (key) return { path: '/issues', query: { issue: key }, hash: '', kind: 'issue' }

  const ch = parentChannelOf(m)
  /* the issue channel is not a place of its own: the Issues tab is */
  if (ch.toLowerCase() === ISSUE_CHANNEL) return { path: '/issues', query: {}, hash: '', kind: 'issue' }
  let path = ''
  let kind = /** @type {'channel' | 'dm'} */ ('channel')
  if (ch) {
    path = '/channel/' + encodeURIComponent(ch)
  } else {
    const peer = dmPeerOf(m, String(o.self || ''))
    if (!peer) return null
    path = '/dm/' + encodeURIComponent(peer)
    kind = 'dm'
  }

  /** @type {Record<string, string>} */
  const query = {}
  /* the card menu (HUM-10 c15b557e): a topic message goes only to the topic
     level, nothing opened. A search row (no is_parent) keeps the old jump. */
  if (o.topicLevel && isTopicStarter(m)) return { path, query, hash: '', kind }
  const open = holdsMessage(o.target, m) ? topicQuery(o.target) : { topic: parentTopicOf(m) || undefined, in: undefined }
  if (open.topic) query.topic = String(open.topic)
  if (open.in) query.in = String(open.in)
  const id = String(m.msg_id || '')
  return { path, query, hash: id ? '#' + id : '', kind }
}

/**
 * The same place as one address.
 * @param {{ path: string, query?: Record<string, string>, hash?: string } | null} section
 * @param {(path: string) => string} [pathFor] locale-aware path, e.g. localePath
 */
export function parentSectionHref(section, pathFor = (p) => p) {
  if (!section || !section.path) return ''
  const qs = new URLSearchParams(section.query || {}).toString()
  return String(pathFor(section.path) || section.path) + (qs ? '?' + qs : '') + (section.hash || '')
}

/**
 * The issue whose discussion is this topic, from an issues-v1 list.
 * @param {unknown} list `{ issues: [...] }` or the array
 * @param {string} taskId
 * @returns {string} the issue key (e.g. SPL-15), or ''
 */
export function issueKeyForTask(list, taskId) {
  const id = String(taskId || '')
  if (!id) return ''
  const rows = Array.isArray(list) ? list : (list && typeof list === 'object' && Array.isArray(list.issues) ? list.issues : [])
  for (const r of rows) {
    if (r && typeof r === 'object' && String(r.task_id || '') === id) return String(r.key || r.issue_key || '')
  }
  return ''
}
