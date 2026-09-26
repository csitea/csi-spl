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
 * @param {{ editable?: boolean, mergePrev?: boolean, mergeNext?: boolean, parent?: boolean }} [opts]
 * @returns {{ id: 'open' | 'parent' | 'edit' | 'copy' | 'merge-prev' | 'merge-next' | 'delete', icon: 'open' | 'parent' | 'pencil' | 'copy' | 'merge' | 'trash', labelKey: string }[]}
 */
export function msgMenuItems(opts = {}) {
  const o = opts && typeof opts === 'object' ? opts : {}
  const editable = Boolean(o.editable)
  const copy = { id: 'copy', icon: 'copy', labelKey: 'feed.msg_menu.copy_link' }
  const edit = { id: 'edit', icon: 'pencil', labelKey: 'feed.msg_menu.edit' }
  const items = [{ id: 'open', icon: 'open', labelKey: 'feed.msg_menu.open' }]
  if (o.parent) items.push({ id: 'parent', icon: 'parent', labelKey: 'feed.msg_menu.open_parent' })
  items.push(copy)
  if (editable) items.push(edit)
  if (editable && o.mergePrev) items.push({ id: 'merge-prev', icon: 'merge', labelKey: 'feed.msg_menu.merge_prev' })
  if (editable && o.mergeNext) items.push({ id: 'merge-next', icon: 'merge', labelKey: 'feed.msg_menu.merge_next' })
  if (editable) items.push({ id: 'delete', icon: 'trash', labelKey: 'feed.msg_menu.delete' })
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
