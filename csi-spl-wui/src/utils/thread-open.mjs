/**
 * Which thread a clicked feed row opens, and how that choice survives a
 * reload (CLE-3427). Pure: the Node tests import this file, the Vue stores
 * and panes wrap it.
 *
 * A thread here is a task_id: its root is the task's oldest message, its
 * replies are the rest (utils/feed.mjs rootAndReplies). A feed row is one of
 * two things, and only the first one could be opened before this lane:
 *
 *  - a thread ROOT of its own — every row on /channel and /dm (the feed is
 *    built by rootsByTask), a search hit from another task. Opening it opens
 *    that task, exactly as the "open thread" control already did.
 *
 *  - one message INSIDE the feed's own task — every row in #lobby, where the
 *    whole channel is a single task. `openable()` in LiveFeed refused those
 *    rows (m.task_id === currentTaskId), so a lobby message had no thread to
 *    open at all. Such a row now opens a MESSAGE-rooted thread: the clicked
 *    message is pinned as the root, and its replies are the messages of the
 *    task whose id IS that message's msg_id, tagged parent_task_id = the task
 *    the message itself was posted in (hub checkTags only requires a UUID
 *    other than task_id). A message nobody has replied to therefore opens
 *    with an empty reply list and a ready composer — which is the point: the
 *    thread exists from the first click, not from the first reply.
 */

/** The `?thread=` / `?in=` pair a target is deep-linked as. */
export function threadQuery(target) {
  if (!target || !target.taskId) return { thread: undefined, in: undefined }
  return target.mode === 'message'
    ? { thread: target.taskId, in: target.parentTaskId || undefined }
    : { thread: target.taskId, in: undefined }
}

/** The target a clicked row opens; null when the row carries no id at all. */
export function threadTargetFor(msg, { currentTaskId = '' } = {}) {
  const m = msg || {}
  const taskId = String(m.task_id || '')
  const msgId = String(m.msg_id || '')
  const here = String(currentTaskId || '')
  /* a row that is its own thread root: the task IS the thread */
  if (taskId && taskId !== here) {
    return { taskId, mode: 'task', rootMsgId: msgId, parentTaskId: '' }
  }
  /* a message inside the feed's own task: the message is the thread */
  if (msgId) {
    return { taskId: msgId, mode: 'message', rootMsgId: msgId, parentTaskId: taskId }
  }
  return null
}

/** The target a URL carries back, or null. `in` is what makes it message-rooted. */
export function targetFromQuery(query) {
  const q = query || {}
  const one = (v) => (Array.isArray(v) ? v[0] : v)
  const taskId = String(one(q.thread) || '')
  if (!taskId) return null
  const parentTaskId = String(one(q.in) || '')
  return parentTaskId
    ? { taskId, mode: 'message', rootMsgId: taskId, parentTaskId }
    : { taskId, mode: 'task', rootMsgId: '', parentTaskId: '' }
}

/** Same thread, in the same mode? (both null counts as same) */
export function sameTarget(a, b) {
  if (!a || !b) return !a && !b
  return a.taskId === b.taskId && a.mode === b.mode && String(a.parentTaskId || '') === String(b.parentTaskId || '')
}

/**
 * The route query for a target, keeping every other parameter (`q`, `tenant`,
 * …) untouched and DROPPING thread/in when the pane closes — a stale
 * ?thread= would re-open it on the next navigation.
 */
export function queryWithThread(query, target) {
  const out = { ...(query || {}) }
  const { thread, in: parent } = threadQuery(target)
  if (thread) out.thread = thread
  else delete out.thread
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

/** Is this row the one the open thread is rooted at? */
export function isSelectedRow(msg, target) {
  const m = msg || {}
  if (!target || !target.taskId) return false
  return target.mode === 'message'
    ? String(m.msg_id || '') === target.rootMsgId
    : String(m.task_id || '') === target.taskId
}
