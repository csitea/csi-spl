// CLE-77840 (owner, t1 topic bc1fd547): "one should be able to delete any msg
// or topic level msg by cycling with the keyboard and when the msg is selected
// pressing the delete button, the same do you want to delete should occur only
// on the is_parent=1 msgs for the others they should be just deleted, but a
// small undo snackbar at the end should appear".
//
// The decisions, kept out of MessageCard.vue so node can test them:
//   rowStep        - ArrowDown / ArrowUp on a focused row walks the feed
//   deleteKeyAction - what Delete / Backspace does on the focused row
// The focused row IS the selected message (main.css .msg:focus-visible).
import { DELETE_KEYS } from './msg-edit.mjs'

/** +1 (ArrowDown), -1 (ArrowUp) or 0: only on the row itself, no modifier. */
export function rowStep(ev) {
  if (!ev || ev.isComposing) return 0
  if (ev.ctrlKey || ev.metaKey || ev.altKey || ev.shiftKey) return 0
  if (ev.target !== ev.currentTarget) return 0
  if (ev.key === 'ArrowDown') return 1
  if (ev.key === 'ArrowUp') return -1
  return 0
}

/** The row `step` away from `current` in `rows` (document order), else null. */
export function stepRow(rows, current, step) {
  const list = Array.from(rows || [])
  const at = list.indexOf(current)
  if (at < 0 || !step) return null
  return list[at + step] || null
}

/** A reply is is_parent 0; anything else (1, or not stated) is topic-level. */
export function isReply(msg) {
  return Boolean(msg) && msg.is_parent != null && Number(msg.is_parent) === 0
}

/**
 * What Delete / Backspace does on the focused row:
 *   'confirm-topic'   - is_parent 1 and the topic menu offers Delete topic:
 *                       the existing "Delete this topic?" confirm
 *   'confirm-message' - is_parent 1, no topic delete, but the message is the
 *                       viewer's to delete: the existing "Delete this message?"
 *   'delete-undo'     - a reply the viewer may delete: at once, with Undo
 *   ''                - nothing (the menu would not offer Delete either)
 * Who may delete is the caller's gate, unchanged: `topicDelete` is the menu's
 * Delete topic, `editable` its Delete.
 */
export function deleteKeyAction(ev, msg, { topicDelete = false, editable = false } = {}) {
  if (!ev || ev.isComposing) return ''
  if (ev.ctrlKey || ev.metaKey || ev.altKey || ev.shiftKey) return ''
  if (!DELETE_KEYS.includes(String(ev.key))) return ''
  if (ev.target !== ev.currentTarget) return ''
  if (isReply(msg)) return editable ? 'delete-undo' : ''
  if (topicDelete) return 'confirm-topic'
  return editable ? 'confirm-message' : ''
}
