/**
 * Topics the Omnibox starts while the right pane is open.
 *
 * They are not replies of the topic already on screen. Each one is its own
 * topic and is shown at the top of that pane, newest first. An `in:` reply
 * names a topic already, so it does not join this list. A closed pane does
 * not collect them: the new message stays a card in the middle feed.
 */

/**
 * @param {unknown[] | null | undefined} rows
 * @param {unknown} paneOpen
 * @param {unknown} topicId  set when `in:` resolved a topic
 * @param {unknown} row
 */
export function noteBornTopic(rows, paneOpen, topicId, row) {
  const list = Array.isArray(rows) ? rows : []
  if (!paneOpen || topicId) return list
  const msg = row || {}
  const id = String(msg.msg_id || '')
  if (!id) return list
  return [msg, ...list.filter((m) => m && m.msg_id !== id)]
}

/** Drop one born topic once the reader opens it as the pane's topic. */
export function dismissBornTopic(rows, msgId) {
  const id = String(msgId || '')
  return (Array.isArray(rows) ? rows : []).filter((m) => m && m.msg_id !== id)
}
