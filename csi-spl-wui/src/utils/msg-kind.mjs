/**
 * SPL-952: message kinds and their badge glyphs. The hub's list is
 * internal/msg validKinds; blocker and msg are the two SPL-952 added.
 * Node tests import this file; KindBadge.vue reads it. A person's post with
 * no kind is a note (owner, 2026-09-26).
 */

/** Every kind the hub accepts, in the order a picker lists them. */
export const MSG_KINDS = ['msg', 'note', 'task', 'blocker', 'result', 'reject']

/** uiIcons glyph per kind; an unknown kind has none and shows as its word. */
export const KIND_ICONS = {
  msg: 'kind-msg',
  note: 'kind-note',
  task: 'kind-task',
  blocker: 'kind-blocker',
  result: 'kind-result',
  reject: 'kind-reject',
}

export function kindIcon(kind) {
  return KIND_ICONS[String(kind || '')] || ''
}

/** Roles the hub lets set ANY readable message's kind (hub message_kind.go). */
export const KIND_SETTER_ROLES = ['biz_owner', 'admin']

/**
 * May this viewer set the message's kind? The hub's own rule (SPL-952): the
 * author, or a biz_owner / admin. A row still in flight has no confirmed id.
 * This only hides the picker; the hub re-checks every change.
 */
export function canSetKind(msg, viewerId, role) {
  const m = msg || {}
  if (!m.msg_id || m.pending) return false
  if (viewerId && String(m.from || '') === String(viewerId)) return true
  return KIND_SETTER_ROLES.includes(String(role || ''))
}
