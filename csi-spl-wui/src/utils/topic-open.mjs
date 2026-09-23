/**
 * Which topic a clicked feed row opens, and how that choice survives a
 * reload (CLE-3427). Pure: the Node tests import this file, the Vue stores
 * and panes wrap it.
 *
 * A topic here is a task_id: its root is the task's oldest message, its
 * replies are the rest (utils/feed.mjs rootAndReplies). A feed row is one of
 * two things, and only the first one could be opened before this lane:
 *
 *  - a topic ROOT of its own — every row on /channel and /dm (the feed is
 *    built by rootsByTask), a search hit from another task. Opening it opens
 *    that task, exactly as the "open topic" control already did.
 *
 *  - one message INSIDE the feed's own task — every row in #lobby, where the
 *    whole channel is a single task. `openable()` in LiveFeed refused those
 *    rows (m.task_id === currentTaskId), so a lobby message had no topic to
 *    open at all. Such a row now opens a MESSAGE-rooted topic: the clicked
 *    message is pinned as the root, and its replies are the messages of the
 *    task whose id IS that message's msg_id, tagged parent_task_id = the task
 *    the message itself was posted in (hub checkTags only requires a UUID
 *    other than task_id). A message nobody has replied to therefore opens
 *    with an empty reply list and a ready composer — which is the point: the
 *    topic exists from the first click, not from the first reply.
 */

/** The `?topic=` / `?in=` pair a target is deep-linked as. */
export function topicQuery(target) {
  if (!target || !target.taskId) return { topic: undefined, in: undefined }
  return target.mode === 'message'
    ? { topic: target.taskId, in: target.parentTaskId || undefined }
    : { topic: target.taskId, in: undefined }
}

/** The target a clicked row opens; null when the row carries no id at all. */
export function topicTargetFor(msg, { currentTaskId = '' } = {}) {
  const m = msg || {}
  const taskId = String(m.task_id || '')
  const msgId = String(m.msg_id || '')
  const here = String(currentTaskId || '')
  /* a row that is its own topic root: the task IS the topic */
  if (taskId && taskId !== here) {
    return { taskId, mode: 'task', rootMsgId: msgId, parentTaskId: '' }
  }
  /* a message inside the feed's own task: the message is the topic */
  if (msgId) {
    return { taskId: msgId, mode: 'message', rootMsgId: msgId, parentTaskId: taskId }
  }
  return null
}

/** The target a URL carries back, or null. `in` is what makes it message-rooted. */
export function targetFromQuery(query) {
  const q = query || {}
  const one = (v) => (Array.isArray(v) ? v[0] : v)
  const taskId = String(one(q.topic) || '')
  if (!taskId) return null
  const parentTaskId = String(one(q.in) || '')
  return parentTaskId
    ? { taskId, mode: 'message', rootMsgId: taskId, parentTaskId }
    : { taskId, mode: 'task', rootMsgId: '', parentTaskId: '' }
}

/** Same topic, in the same mode? (both null counts as same) */
export function sameTarget(a, b) {
  if (!a || !b) return !a && !b
  return a.taskId === b.taskId && a.mode === b.mode && String(a.parentTaskId || '') === String(b.parentTaskId || '')
}

/**
 * The route query for a target, keeping every other parameter (`q`, `tenant`,
 * …) untouched and DROPPING topic/in when the pane closes — a stale
 * ?topic= would re-open it on the next navigation.
 */
export function queryWithTopic(query, target) {
  const out = { ...(query || {}) }
  const { topic, in: parent } = topicQuery(target)
  if (topic) out.topic = topic
  else delete out.topic
  if (parent) out.in = parent
  else delete out.in
  return out
}

/** Do two route queries say the same thing? (order-insensitive, string-compared) */
export function sameQuery(a, b) {
  const norm = (q) => Object.entries(q || {})
    .filter(([, v]) => v !== undefined && v !== null)
    .map(([k, v]) => [k, String(Array.isArray(v) ? v[0] : v)])
    .sort((x, y) => x[0].localeCompare(y[0]))
  return JSON.stringify(norm(a)) === JSON.stringify(norm(b))
}

/** Is this row the one the open topic is rooted at? */
export function isSelectedRow(msg, target) {
  const m = msg || {}
  if (!target || !target.taskId) return false
  return target.mode === 'message'
    ? String(m.msg_id || '') === target.rootMsgId
    : String(m.task_id || '') === target.taskId
}

/**
 * Clicks that already have a job inside the topic pane. A close button, the
 * open-topic link, and the editor must not also move the selection.
 */
export const TOPIC_PANE_OWN_CLICK = 'button, a, input, textarea, select, label, summary, [role="button"]'

/**
 * What a click in the topic pane does to the selection.
 * 'pane' — the pane becomes the selected surface and the message highlight goes.
 * '' — a control, or a drag that is selecting text: leave the selection as it is.
 */
export function topicPaneClickAction(el, { selecting = false } = {}) {
  if (selecting) return ''
  if (el && typeof el.closest === 'function' && el.closest(TOPIC_PANE_OWN_CLICK)) return ''
  return 'pane'
}
