/**
 * CLE-3433 / OA-38 — which conversation the top-bar Omnibox is writing into.
 *
 * `layouts/default.vue` can have a thread pane open beside the feed, and
 * `?thread=<id>` in the URL says which thread that is. The Omnibox kept
 * sending to the FEED regardless, and `stores/channel.ts sendLive()` does
 * `task_id: parentTaskId || newId()` — so every send from a page whose URL
 * named a thread minted a NEW task. Measured by CLE-3438 on dev (tree
 * f76f648, n=1): 12 messages sent from one `/dm/<peer>?thread=<id>` page
 * produced 12 distinct task ids in the peer's inbox. The owner's exchange
 * scattered into twelve conversations, and an agent's reply into one of them
 * did not appear beside the others.
 *
 * The URL is the statement of intent: while it names a thread, that is where
 * the page's composer writes. Closing the pane clears `?thread=` and the
 * Omnibox goes back to starting new messages in the feed, so nothing is
 * trapped.
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
