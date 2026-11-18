// SPL-5836 (HUM-10, t1 0cd27035): while the Kind picker is open, one plain
// letter picks a kind, the same as a click on it. Owner: "add the shortcuts
// ( the implmentation ) and the shortcuts labels to those".
//
// One letter per kind, unique: M message, N note, T task, B blocker,
// R result, J reJect (R is result's). The picker shows the letter on the
// right of each item, as the message menu shows its keys, and both the
// letter and its hint follow the Keyboard shortcuts setting (spec 081
// FR-012, FR-016). The listener is KindPicker.vue's onKey; the rule lives
// here so node can test it.

/** The letter of each kind the hub accepts (utils/msg-kind.mjs MSG_KINDS). */
export const KIND_KEYS: Readonly<Record<string, string>> = Object.freeze({
  msg: 'M',
  note: 'N',
  task: 'T',
  blocker: 'B',
  result: 'R',
  reject: 'J',
})

/** The hint a picker item shows on its right ("M"), '' for a kind with no key. */
export function kindKeyHint(kind: unknown): string {
  return KIND_KEYS[String(kind || '')] || ''
}

export interface KindKeyEvent {
  key?: string
  code?: string
  shiftKey?: boolean
  ctrlKey?: boolean
  metaKey?: boolean
  altKey?: boolean
  isComposing?: boolean
  repeat?: boolean
}

/**
 * The Latin letter a keydown names, '' when none: `ev.key` when it is A-Z,
 * else the physical key's `KeyX` from `ev.code`, so a Cyrillic or Greek
 * layout ('т' on KeyT) still picks (SPL-5836 R7 W1). The same rule as
 * `letterOf` in utils/msg-shortcuts.mjs, mirrored because that one is
 * module-private and that file is not this change's to edit.
 */
function letterOf(ev: KindKeyEvent): string {
  const key = String(ev.key || '')
  if (/^[A-Za-z]$/.test(key)) return key.toUpperCase()
  const m = /^Key([A-Z])$/.exec(String(ev.code || ''))
  return m ? m[1] : ''
}

/**
 * The kind one keydown picks, '' when none: a plain letter (no Shift, Ctrl,
 * Cmd or Alt), not held down, naming a kind the picker offers.
 */
export function kindForKey(ev: KindKeyEvent | null | undefined, offered: readonly string[]): string {
  if (!ev || ev.isComposing || ev.repeat) return ''
  if (ev.shiftKey || ev.ctrlKey || ev.metaKey || ev.altKey) return ''
  const letter = letterOf(ev)
  if (!letter) return ''
  return (offered || []).find((k) => KIND_KEYS[k] === letter) || ''
}
