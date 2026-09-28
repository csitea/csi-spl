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
 * SPL-996, owner answer B (topic e0b12a2c, 2026-09-27) - replaces the 09-25
 * "the pane you clicked last decides" rule: a post goes into the OPEN topic
 * until the reader closes it (X, or Back on a phone). A click on a middle
 * card no longer changes the target; `lastPane` is accepted and ignored.
 * A new topic is explicit: the pane closed, a line that starts with
 * `@someone` (`newTopic`, see startsNewTopic), or `in:` naming another topic.
 * Topics with a selected row replies there as before.
 * @param {{ tab?: string, selectedTaskId?: string, namedTopicId?: string, paneVisible?: boolean, lastPane?: string, newTopic?: boolean }} [opts]
 */
export function omniboxReplyTaskId({ tab = '', selectedTaskId = '', namedTopicId = '', paneVisible = false, newTopic = false } = {}) {
  const named = String(namedTopicId || '')
  if (named) return named
  if (newTopic) return ''
  const selected = String(selectedTaskId || '')
  if (paneVisible && selected) return selected
  if (tab === 'topics' && selected) return selected
  return ''
}

/**
 * SPL-996 B: a line that opens with `@someone` is the explicit "new topic",
 * even while a topic is open. An `@` later in the line is a mention inside
 * the reply.
 * @param {unknown} text
 */
export function startsNewTopic(text) {
  return /^\s*@[A-Za-z0-9_][\w.@-]*/.test(String(text || ''))
}

/**
 * messages.is_parent for a browser send.
 * 0 while the right topic pane takes the line (open, SPL-996 B): that message
 * stays in the pane. 1 when the pane is closed or the line is an explicit new
 * topic (the caller passes paneVisible false): the send is a new middle card.
 * SPL-996: a send that goes INTO an existing topic (`replyTaskId`, e.g. an
 * `in: <title>` with the pane closed) is always 0. It used to go out as 1
 * under the old task id, so that topic had two openings and the reply was
 * drawn as a middle card as well as a line of the thread.
 * @param {{ paneVisible?: boolean, lastPane?: string, replyTaskId?: string }} [opts]  lastPane is ignored
 * @returns {0 | 1}
 */
export function isParentFlag({ paneVisible = false, replyTaskId = '' } = {}) {
  if (replyTaskId) return 0
  return paneVisible ? 0 : 1
}

/**
 * SPL-1003 (owner, prd t1 #spool-hub-mobile, 2026-09-27): on a phone the
 * docked composer says where the post goes BEFORE it is sent - the open
 * thread (a reply, is_parent 0) or a new topic in the page's feed. The
 * owner's 12:10Z line was typed in an open thread and stored as a new topic
 * (is_parent 1) with nothing on screen to tell him.
 * `dock` is the page's omnibox target `dock()`; `text` the line as typed:
 * a line that opens with `@someone` is the explicit new topic (SPL-996 B)
 * even while a thread is open, so the hint follows it.
 * @param {{ reply?: boolean, target?: string, comment?: boolean } | null | undefined} dock
 * @param {unknown} [text]
 * @returns {{ mode: 'thread' | 'new' | 'comment', target: string } | null}
 */
export function dockTargetHint(dock, text = '') {
  if (!dock) return null
  /* CLE-35066: an open issue takes every line as a comment - no new topic */
  if (dock.comment) return { mode: 'comment', target: String(dock.target || '') }
  const reply = Boolean(dock.reply) && !startsNewTopic(text)
  return { mode: reply ? 'thread' : 'new', target: String(dock.target || '') }
}
