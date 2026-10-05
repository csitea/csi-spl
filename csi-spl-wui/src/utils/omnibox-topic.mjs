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

import { parseMention } from './channel-feed.mjs'

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
 * SPL-996 B: a line that DISPATCHES a task to an addressed agent
 * (`@CLE-07 do X`) is the explicit "new topic", even while a topic is open.
 *
 * e09a72f7 (owner): it must be a real dispatch, not merely a leading `@`. The
 * owner typed `@test` inside an open thread and every one became its own topic
 * instead of a reply. Plain text that happens to start with `@` (`@test`), a
 * BARE mention with nothing after it (`@CLE-07`), a lone `@`, and an `@` later
 * in the line address no task, so they are ordinary messages and reply into
 * the open thread. parseMention is the single source of what "addresses a
 * task" is — kind 'task' only for `@<ID> <instructions>` — so this follows it,
 * and the two can never drift apart. Leading whitespace is ignored.
 * @param {unknown} text
 */
export function startsNewTopic(text) {
  return parseMention(String(text || '').replace(/^\s+/, '')).kind === 'task'
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
 * HUM-24 (CLE-77879): `dm` marks a direct-message page (a new topic there is
 * "with" the peer).
 * @param {{ reply?: boolean, target?: string, comment?: boolean, dm?: boolean } | null | undefined} dock
 * @param {unknown} [text]
 * @returns {{ mode: 'thread' | 'new' | 'dm' | 'comment', target: string } | null}
 */
export function dockTargetHint(dock, text = '') {
  if (!dock) return null
  const target = String(dock.target || '')
  /* an open issue takes every line as a comment - no new topic */
  if (dock.comment) return { mode: 'comment', target }
  const reply = Boolean(dock.reply) && !startsNewTopic(text)
  if (reply) return { mode: 'thread', target }
  return { mode: dock.dm ? 'dm' : 'new', target }
}

/**
 * 080 FR-006 / FR-007: the chip at the start of the box names where Enter
 * sends, from the very target `send` uses - the page's `dock()` (reply or a
 * new topic, an `@ID task` line is a new topic: dockTargetHint) and its
 * `place()` (`ch:` / `dm:` / `t:`, the same replyTarget() the send reads).
 * An `in: <title>` the line resolves to (`named`) wins, as it does in send.
 * No chip for an empty box, a `/search` line or a page with no send target.
 * `key` '' means `text` is the label as is (`#feedback`, `@HUM-3`); `open`
 * is the place a click on the chip opens ('' opens nothing).
 * @param {{ dock?: { reply?: boolean, target?: string, comment?: boolean, dm?: boolean } | null, place?: string, text?: unknown, named?: { taskId?: string, title?: string } | null, title?: string }} [opts]
 * @returns {{ key: string, params: Record<string, string>, text: string, open: string } | null}
 */
export function chipLabel({ dock = null, place = '', text = '', named = null, title = '' } = {}) {
  const line = String(text || '')
  if (!dock || !line.trim() || /^\/search(\s|$)/i.test(line.trimStart())) return null
  const reply = (t, open) => ({ key: 'composer.chip_reply', params: { title: t }, text: '', open })
  if (named && named.taskId) return reply(String(named.title || named.taskId), `t:${named.taskId}`)
  const hint = dockTargetHint(dock, line)
  if (!hint) return null
  const at = String(place || '')
  if (hint.mode === 'comment') return reply(hint.target, '')
  if (hint.mode === 'thread') {
    const id = at.startsWith('t:') ? at.slice(2) : ''
    return reply(String(title || id || hint.target), id ? at : '')
  }
  let where = ''
  if (at.startsWith('ch:') && at.length > 3) where = '#' + at.slice(3)
  else if (at.startsWith('dm:') && at.length > 3) where = '@' + at.slice(3)
  else where = hint.mode === 'dm' ? '@' + hint.target.replace(/^@/, '') : hint.target
  /* a topic is open and the line still starts a new one: say so */
  if (dock.reply) return { key: 'composer.chip_new_topic', params: { target: where }, text: '', open: '' }
  return { key: '', params: {}, text: where, open: where ? at : '' }
}

/**
 * HUM-24 (CLE-77879, 2026-10-01): "creating a new topic must look different
 * from writing a reply in the chat". The line over the phone / bottom dock
 * for a hint, as an i18n key and its params (the desktop bottom dock only).
 * @param {{ mode: string, target?: string } | null | undefined} hint
 * @returns {{ key: string, params: Record<string, string> } | null}
 */
export function composerModeLabel(hint) {
  if (!hint) return null
  const target = String(hint.target || '')
  if (hint.mode === 'thread') return { key: 'composer.target_thread', params: {} }
  if (hint.mode === 'comment') return { key: 'composer.target_comment', params: { target } }
  if (hint.mode === 'dm') return { key: 'composer.target_dm', params: { target } }
  return { key: 'composer.target_new', params: { target } }
}

/**
 * HUM-24: the GO button says what it does in this mode - start a topic, send
 * a reply, post a comment. No hint (no send target, /search) keeps "Go / Send".
 * @param {{ mode: string } | null | undefined} hint
 * @returns {string}
 */
export function composerSendKey(hint) {
  if (!hint) return 'composer.go'
  if (hint.mode === 'thread') return 'composer.go_reply'
  if (hint.mode === 'comment') return 'composer.go_comment'
  return 'composer.go_new'
}
