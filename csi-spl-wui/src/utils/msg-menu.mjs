/**
 * Right-click menu on a message. Same shape as the left-pane row menu:
 * an icon and a translated name per action. Edit and Delete are the author's
 * own browser message only — the same gate as the e shortcut. Copy link is
 * on every message.
 *
 * @param {{ editable?: boolean }} [opts]
 * @returns {{ id: 'edit' | 'copy' | 'delete', icon: 'pencil' | 'copy' | 'trash', labelKey: string }[]}
 */
export function msgMenuItems(opts = {}) {
  const editable = Boolean(opts && opts.editable)
  const items = []
  if (editable) items.push({ id: 'edit', icon: 'pencil', labelKey: 'feed.msg_menu.edit' })
  items.push({ id: 'copy', icon: 'copy', labelKey: 'feed.msg_menu.copy_link' })
  if (editable) items.push({ id: 'delete', icon: 'trash', labelKey: 'feed.msg_menu.delete' })
  return items
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
