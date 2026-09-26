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
