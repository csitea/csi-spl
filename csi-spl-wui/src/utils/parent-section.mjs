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
 * Where "Open parent section" goes, or null when the message names no
 * channel and no other DM end (a broadcast, a row with no ids).
 *
 * @param {unknown} msg the thread message
 * @param {{ self?: string, target?: { taskId?: string, mode?: string, parentTaskId?: string } | null, issueKey?: string }} [opts]
 *   self: the viewer's id (the DM end that is not the peer);
 *   target: the topic open on the right, kept as it is when it holds this message;
 *   issueKey: the issue whose discussion this topic is, when there is one
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
