/**
 * Owner priority (t1 48d09034): a link to a message opens THAT message, also
 * when the reader already has its topic open and the address does not change
 * (the same #<msg_id> clicked twice, or /m/<msg_id> that comes back to the
 * address already shown). The router sees no new hash then, so the thread
 * feed (LiveFeed) is told directly: every in-app link that names a message
 * (link-target.mjs) and every open of a message (open-message.mjs) calls
 * requestMessageJump; the feed holding that topic reads older pages until the
 * row is there, scrolls it to the top of the pane and highlights it.
 *
 * No Vue here: the link code stays plain, and this file is a few lines in the
 * initial chunk.
 */

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
const HASH_RE = new RegExp(`#(${UUID})$`, 'i')
const DEEP_RE = new RegExp(`(?:^|/)m/(${UUID})(?:[?#]|$)`, 'i')

/** How long a jumped-to message stays highlighted (open-message.mjs OPEN_FOCUS_MS). */
export const JUMP_FOCUS_MS = 2000

/** The message an in-app path names: its #<msg_id>, or /m/<msg_id>. '' for none. */
export function messageIdOfPath(path) {
  const s = String(path || '')
  const m = HASH_RE.exec(s) || DEEP_RE.exec(s)
  return m ? m[1].toLowerCase() : ''
}

const listeners = new Set()

/** Listen for jump requests; returns the unsubscribe. */
export function onMessageJump(fn) {
  if (typeof fn !== 'function') return () => {}
  listeners.add(fn)
  return () => { listeners.delete(fn) }
}

/** Ask every feed that may hold `msgId` to bring it into view. */
export function requestMessageJump(msgId) {
  const id = String(msgId || '').toLowerCase()
  if (!new RegExp(`^${UUID}$`).test(id)) return false
  for (const fn of [...listeners]) {
    try { fn(id) } catch { /* one feed failing must not stop the others */ }
  }
  return true
}

/** The navigate wrapper: route to `path`, then ask for the jump it names. */
export function navigateAndJump(path, navigate) {
  navigate(path)
  const id = messageIdOfPath(path)
  /* after the router has started: a same-address push is a no-op for it */
  if (id) queueMicrotask(() => requestMessageJump(id))
}
