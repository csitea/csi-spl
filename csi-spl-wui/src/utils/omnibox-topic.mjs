/**
 * CLE-3433 / OA-38 — the open topic pane used to be where the Omnibox wrote.
 *
 * That binding is no longer the rule. Measured by CLE-3438 on dev (tree
 * f76f648, n=1): 12 messages sent from one `/dm/<peer>?topic=<id>` page
 * produced 12 distinct task ids, because the page passed no parent and
 * `sendLive` does `task_id: parentTaskId || newId()`. Binding every send to
 * the open pane fixed the scatter and then made a new message impossible
 * while a topic was open.
 *
 * The line decides now (`utils/topic-in.mjs`): `in: <topic title>` replies
 * into that topic, and `@receiver` — or any line that does not name a topic
 * — starts a new message. These helpers still describe the pane itself. The
 * Omnibox does not read them.
 */

/**
 * The task a send from this page should hang off, or '' for a new one.
 * Reads a topic store's public shape, so it is the same rule on every page
 * that has one.
 * @param {{ open?: unknown, parentTaskId?: unknown } | null | undefined} topic
 */
export function omniboxParentTaskId(topic) {
  if (!topic || !topic.open) return ''
  return String(topic.parentTaskId || '')
}

/**
 * Which placeholder the Omnibox shows: a reply into the open topic reads as
 * a reply, or the box goes on saying it starts a new message to the feed. A
 * box that sends somewhere it does not name is how OA-38 went unnoticed.
 * @param {string} parentTaskId  the result of omniboxParentTaskId()
 */
export function omniboxPlaceholderKey(parentTaskId) {
  return parentTaskId ? 'topic.reply_placeholder' : ''
}

/**
 * The right pane is closed and the line does not name a topic with `in:`.
 * That send is a new topic whose only message is the one just written.
 * An open pane, or a line that names a topic, is not this case.
 */
export function sendsNewTopic({ paneOpen = false, namedTopicId = '' } = {}) {
  return !paneOpen && !namedTopicId
}

/**
 * `in: <title>` replies into that topic. An open right pane does too while it
 * is the pane the reader selected last (utils/pane-focus.mjs): that is the
 * pane a replies click shows, and the left tab stays where it was. Topics
 * with a selected row replies there when the pane is not what decided.
 * `lastPane: 'middle'` means the reader went back to the middle list: the
 * line starts a new topic whatever is open or selected.
 * @param {{ tab?: string, selectedTaskId?: string, namedTopicId?: string, paneVisible?: boolean, lastPane?: string }} [opts]
 */
export function omniboxReplyTaskId({ tab = '', selectedTaskId = '', namedTopicId = '', paneVisible = false, lastPane = '' } = {}) {
  const named = String(namedTopicId || '')
  if (named) return named
  if (lastPane === 'middle') return ''
  const selected = String(selectedTaskId || '')
  if (paneVisible && selected) return selected
  if (tab === 'topics' && selected) return selected
  return ''
}

/**
 * messages.is_parent for a browser send.
 * 0 while the right topic pane is open and was selected last (the replies
 * click). That message stays in the pane. 1 when the pane is closed, or the
 * reader went back to the middle: the send is a new middle card.
 * SPL-996: a send that goes INTO an existing topic (`replyTaskId`, e.g. an
 * `in: <title>` with the pane closed) is always 0. It used to go out as 1
 * under the old task id, so that topic had two openings and the reply was
 * drawn as a middle card as well as a line of the thread.
 * @param {{ paneVisible?: boolean, lastPane?: string, replyTaskId?: string }} [opts]
 * @returns {0 | 1}
 */
export function isParentFlag({ paneVisible = false, lastPane = '', replyTaskId = '' } = {}) {
  if (replyTaskId) return 0
  return paneVisible && lastPane !== 'middle' ? 0 : 1
}
