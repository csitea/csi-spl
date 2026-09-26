/**
 * SPL-952: message kinds and their badge glyphs. The hub's list is
 * internal/msg validKinds; blocker and msg are the two SPL-952 added.
 * Node tests import this file; KindBadge.vue and the composer read it.
 */

/** Every kind the hub accepts, in the order a picker lists them. */
export const MSG_KINDS = ['msg', 'note', 'task', 'blocker', 'result', 'reject']

/** What a person may pick in the composer ('' = automatic). */
export const PICK_KINDS = ['', 'msg', 'note', 'task', 'blocker']

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

/**
 * The kind a send carries: the composer's pick when it is one a person may
 * pick, else the automatic one (an @mention is a task, anything else a note).
 */
export function sendKind(auto, picked) {
  const p = String(picked || '')
  return p && PICK_KINDS.includes(p) ? p : auto
}
