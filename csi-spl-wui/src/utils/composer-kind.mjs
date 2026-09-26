/**
 * The kind of the next message the person sends. Clicking a kind icon
 * sets it. The default is a note. A mention no longer changes it.
 */
export const COMPOSER_KINDS = ['note', 'task', 'blocker', 'msg']

let current = 'note'

export function composerKind() {
  return current
}

export function setComposerKind(kind) {
  const k = String(kind || '')
  if (COMPOSER_KINDS.includes(k)) current = k
  return current
}
