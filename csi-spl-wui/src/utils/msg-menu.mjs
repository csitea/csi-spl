import { queryWithTopic, topicTargetFor } from './topic-open.mjs'

/**
 * Right-click menu on a message. Same shape as the left-pane row menu:
 * an icon and a translated name per action. Edit and Delete are the author's
 * own browser message only — the same gate as the e shortcut. Copy link is
 * on every message.
 *
 * Every message also has Open: a topic card in the middle (is_topic=1) opens
 * its topic on the right, as the replies button does; a thread line is
 * selected and scrolled into view. The order is Open, Copy link, Edit.
 *
 * A thread line (`parent`, CLE-34996) also has Open parent section, right
 * after Open: the channel or DM the thread lives in, the parent card
 * selected there and the thread kept open (utils/parent-section.mjs).
 *
 * A topic card the viewer may change (`topic`, SPL-983 / specs/041: its
 * author, the tenant owner or an admin) ends with Archive and Delete, each
 * with its Material glyph on the left. That Delete removes the card AND every
 * child, so it replaces the one-message Delete: deleting the card alone would
 * strand its replies.
 *
 * SPL-1024 (specs/045): a card the viewer may move (`moveChannel`: its
 * author, the tenant owner or an admin, a channel topic) gets Move to
 * channel…, a reply they may move (`moveTopic`) Move to topic…, right before
 * the Archive / Delete block. It is the keyboard and touch way to do what the
 * drag does.
 *
 * On a phone (`touch`, SPL-991) the menu is the long-press bottom sheet, the
 * only way to reach what a desktop row shows on hover: it starts with Reply
 * and Add emoji (the row's smile button is hidden on a phone), and adds Copy text, and Kind when the viewer may re-type the message
 * (`kind`; the desktop keeps that on the kind badge). The desktop menu is
 * unchanged.
 *
 * @param {{ editable?: boolean, mergePrev?: boolean, mergeNext?: boolean, parent?: boolean, topic?: boolean, touch?: boolean, kind?: boolean, moveChannel?: boolean, moveTopic?: boolean }} [opts]
 * @returns {{ id: 'reply' | 'react' | 'open' | 'parent' | 'edit' | 'copy' | 'copy-text' | 'kind' | 'merge-prev' | 'merge-next' | 'move-channel' | 'move-topic' | 'delete' | 'archive' | 'delete-topic', icon: 'reply' | 'smile' | 'open' | 'parent' | 'pencil' | 'copy' | 'tag' | 'merge' | 'move' | 'trash' | 'archive' | 'delete', labelKey: string }[]}
 */
export function msgMenuItems(opts = {}) {
  const o = opts && typeof opts === 'object' ? opts : {}
  const editable = Boolean(o.editable)
  const touch = Boolean(o.touch)
  const copy = { id: 'copy', icon: 'copy', labelKey: 'feed.msg_menu.copy_link' }
  const edit = { id: 'edit', icon: 'pencil', labelKey: 'feed.msg_menu.edit' }
  const items = []
  if (touch) {
    items.push({ id: 'reply', icon: 'reply', labelKey: 'feed.msg_menu.reply' })
    items.push({ id: 'react', icon: 'smile', labelKey: 'feed.emoji.add' })
  }
  items.push({ id: 'open', icon: 'open', labelKey: 'feed.msg_menu.open' })
  if (o.parent) items.push({ id: 'parent', icon: 'parent', labelKey: 'feed.msg_menu.open_parent' })
  if (touch) items.push({ id: 'copy-text', icon: 'copy', labelKey: 'feed.msg_menu.copy_text' })
  items.push(copy)
  if (editable) items.push(edit)
  if (touch && o.kind) items.push({ id: 'kind', icon: 'tag', labelKey: 'feed.msg_menu.kind' })
  if (editable && o.mergePrev) items.push({ id: 'merge-prev', icon: 'merge', labelKey: 'feed.msg_menu.merge_prev' })
  if (editable && o.mergeNext) items.push({ id: 'merge-next', icon: 'merge', labelKey: 'feed.msg_menu.merge_next' })
  if (o.moveChannel) items.push({ id: 'move-channel', icon: 'move', labelKey: 'feed.msg_menu.move_channel' })
  if (o.moveTopic) items.push({ id: 'move-topic', icon: 'move', labelKey: 'feed.msg_menu.move_topic' })
  if (o.topic) {
    items.push({ id: 'archive', icon: 'archive', labelKey: 'feed.msg_menu.archive' })
    items.push({ id: 'delete-topic', icon: 'delete', labelKey: 'feed.msg_menu.delete' })
  } else if (editable) {
    items.push({ id: 'delete', icon: 'trash', labelKey: 'feed.msg_menu.delete' })
  }
  return items
}

function at(m) {
  return String((m && (m.received_at || m.ts)) || '')
}

/** The thread is the task. A row with no task is not in a thread. */
function threadKey(m) {
  return String((m && m.task_id) || '')
}

/**
 * The message sent immediately before or after `msg` in the same thread.
 *
 * `rows` is the list on screen. Previous is the older neighbor, next is the
 * newer one. A message from another task is not a neighbor, even when it
 * sits next to this row in a mixed list.
 *
 * @param {unknown[]} rows
 * @param {unknown} msg
 * @param {'previous' | 'next'} which
 * @returns {object | null}
 */
export function threadNeighbor(rows, msg, which) {
  const id = String((msg && msg.msg_id) || '')
  const key = threadKey(msg)
  if (!id || !key || (which !== 'previous' && which !== 'next')) return null
  const peers = (Array.isArray(rows) ? rows : []).filter((m) => m && threadKey(m) === key && String(m.msg_id || ''))
  peers.sort((a, b) => {
    const c = at(a).localeCompare(at(b))
    return c !== 0 ? c : String(a.msg_id || '').localeCompare(String(b.msg_id || ''))
  })
  const i = peers.findIndex((m) => String(m.msg_id) === id)
  if (i < 0) return null
  if (which === 'previous') return i > 0 ? peers[i - 1] : null
  return i < peers.length - 1 ? peers[i + 1] : null
}

/**
 * CLE-35064: may `msg` be merged AWAY (deleted into a neighbor)? Not when it
 * opens its topic: a task's first row with is_parent 1 is the topic's card,
 * and the hub refuses it (409 is_card) rather than leave a topic with no
 * card. Lobby rows are each their own card and stay mergeable. A row whose
 * older neighbor is not loaded reads as the first one, so the item is then
 * hidden, never offered and refused.
 *
 * @param {unknown[]} rows
 * @param {unknown} msg
 * @param {string} [lobbyTaskId]
 */
export function mergeableSource(rows, msg, lobbyTaskId = '') {
  const m = msg && typeof msg === 'object' ? msg : null
  if (!m) return false
  const task = threadKey(m)
  if (m.is_parent === 0 || (task && task === String(lobbyTaskId || ''))) return true
  return threadNeighbor(rows, m, 'previous') !== null
}

/**
 * Both bodies, older first, as one message. A blank line keeps the two
 * parts apart. Empty sides contribute nothing.
 *
 * @param {unknown} older
 * @param {unknown} newer
 */
export function joinBodies(older, newer) {
  const a = String(older == null ? '' : older).replace(/\s+$/, '')
  const b = String(newer == null ? '' : newer).replace(/^\s+/, '')
  if (!a) return b
  if (!b) return a
  return `${a}\n\n${b}`
}

/**
 * The address copied for one message: the topic page, with the message id
 * as the hash, so two messages in one topic do not share a link.
 *
 * @param {unknown} msg
 * @param {(path: string) => string} pathFor locale-aware path, e.g. localePath
 * @returns {string} a path, or '' when the message names no topic
 */
export function messageLink(msg, pathFor) {
  const m = msg && typeof msg === 'object' ? msg : {}
  const task = String(m.task_id || m.parent_task_id || '')
  const id = String(m.msg_id || '')
  if (!task || typeof pathFor !== 'function') return ''
  const path = String(pathFor('/t/' + task) || '')
  if (!path) return ''
  return id ? `${path}#${id}` : path
}

/**
 * The address copied for a topic card in the middle pane: this page, with
 * the card's topic in ?topic= (and ?in= for a #lobby message). Pasting it
 * opens the same list with that topic open in the right pane. Every other
 * query parameter is kept.
 *
 * @param {unknown} msg
 * @param {{ path?: string, query?: Record<string, unknown>, currentTaskId?: string }} [where]
 * @returns {string} a path with a query, or '' when the card names no topic
 */
export function topicPaneLink(msg, where = {}) {
  const w = where && typeof where === 'object' ? where : {}
  const path = String(w.path || '')
  const target = topicTargetFor(msg, { currentTaskId: String(w.currentTaskId || '') })
  if (!path || !target) return ''
  return withQuery(path, queryWithTopic(w.query || {}, target))
}

/**
 * The address copied for a thread line in the right pane: this page with the
 * open topic kept in ?topic= / ?in=, and the line's id as the hash. Pasting it
 * opens the pane and scrolls to that line. A page with no ?topic= (the
 * /t/<task> page) falls back to messageLink.
 *
 * @param {unknown} msg
 * @param {{ path?: string, query?: Record<string, unknown>, pathFor?: (path: string) => string }} [where]
 * @returns {string}
 */
export function threadLineLink(msg, where = {}) {
  const w = where && typeof where === 'object' ? where : {}
  const query = w.query && typeof w.query === 'object' ? w.query : {}
  const topic = Array.isArray(query.topic) ? query.topic[0] : query.topic
  const path = String(w.path || '')
  if (!topic || !path) return messageLink(msg, w.pathFor)
  const id = String((msg && msg.msg_id) || '')
  const url = withQuery(path, query)
  return id ? `${url}#${id}` : url
}

function withQuery(path, query) {
  const qs = new URLSearchParams()
  for (const [k, v] of Object.entries(query || {})) {
    for (const one of Array.isArray(v) ? v : [v]) {
      if (one !== undefined && one !== null) qs.append(k, String(one))
    }
  }
  const text = qs.toString()
  return text ? `${path}?${text}` : path
}
