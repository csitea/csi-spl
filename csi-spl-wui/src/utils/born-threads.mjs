/**
 * Threads the Omnibox starts while the right pane is open.
 *
 * They are not replies of the thread already on screen. Each one is its own
 * thread and is shown at the top of that pane, newest first. An `in:` reply
 * names a thread already, so it does not join this list. A closed pane does
 * not collect them: the new message stays a card in the middle feed.
 */

/**
 * @param {unknown[] | null | undefined} rows
 * @param {unknown} paneOpen
 * @param {unknown} threadId  set when `in:` resolved a thread
 * @param {unknown} row
 */
export function noteBornThread(rows, paneOpen, threadId, row) {
  const list = Array.isArray(rows) ? rows : []
  if (!paneOpen || threadId) return list
  const msg = row || {}
  const id = String(msg.msg_id || '')
  if (!id) return list
  return [msg, ...list.filter((m) => m && m.msg_id !== id)]
}

/** Drop one born thread once the reader opens it as the pane's thread. */
export function dismissBornThread(rows, msgId) {
  const id = String(msgId || '')
  return (Array.isArray(rows) ? rows : []).filter((m) => m && m.msg_id !== id)
}
