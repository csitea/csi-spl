/**
 * CLE-3433 / OA-38 — the open thread pane used to be where the Omnibox wrote.
 *
 * That binding is no longer the rule. Measured by CLE-3438 on dev (tree
 * f76f648, n=1): 12 messages sent from one `/dm/<peer>?thread=<id>` page
 * produced 12 distinct task ids, because the page passed no parent and
 * `sendLive` does `task_id: parentTaskId || newId()`. Binding every send to
 * the open pane fixed the scatter and then made a new message impossible
 * while a thread was open.
 *
 * The line decides now (`utils/thread-in.mjs`): `in: <thread title>` replies
 * into that thread, and `@receiver` — or any line that does not name a thread
 * — starts a new message. These helpers still describe the pane itself. The
 * Omnibox does not read them.
 */

/**
 * The task a send from this page should hang off, or '' for a new one.
 * Reads a thread store's public shape, so it is the same rule on every page
 * that has one.
 * @param {{ open?: unknown, parentTaskId?: unknown } | null | undefined} thread
 */
export function omniboxParentTaskId(thread) {
  if (!thread || !thread.open) return ''
  return String(thread.parentTaskId || '')
}

/**
 * Which placeholder the Omnibox shows: a reply into the open thread reads as
 * a reply, or the box goes on saying it starts a new message to the feed. A
 * box that sends somewhere it does not name is how OA-38 went unnoticed.
 * @param {string} parentTaskId  the result of omniboxParentTaskId()
 */
export function omniboxPlaceholderKey(parentTaskId) {
  return parentTaskId ? 'thread.reply_placeholder' : ''
}

/**
 * The right pane is closed and the line does not name a thread with `in:`.
 * That send is a new thread whose only message is the one just written.
 * An open pane, or a line that names a thread, is not this case.
 */
export function sendsNewThread({ paneOpen = false, namedThreadId = '' } = {}) {
  return !paneOpen && !namedThreadId
}
