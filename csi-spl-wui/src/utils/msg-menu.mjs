/**
 * Right-click menu on a message. Same shape as the left-pane row menu:
 * an icon and a translated name per action. Edit and Delete are the author's
 * own browser message only — the same gate as the e shortcut. Copy link is
 * on every message.
 *
 * @param {{ editable?: boolean, mergePrev?: boolean, mergeNext?: boolean }} [opts]
 * @returns {{ id: 'edit' | 'copy' | 'merge-prev' | 'merge-next' | 'delete', icon: 'pencil' | 'copy' | 'merge' | 'trash', labelKey: string }[]}
 */
export function msgMenuItems(opts = {}) {
  const o = opts && typeof opts === 'object' ? opts : {}
  const editable = Boolean(o.editable)
  const items = []
  if (editable) items.push({ id: 'edit', icon: 'pencil', labelKey: 'feed.msg_menu.edit' })
  items.push({ id: 'copy', icon: 'copy', labelKey: 'feed.msg_menu.copy_link' })
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
