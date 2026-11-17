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
  shiftKey?: boolean
  ctrlKey?: boolean
  metaKey?: boolean
  altKey?: boolean
  isComposing?: boolean
  repeat?: boolean
}

/**
 * The kind one keydown picks, '' when none: a plain letter (no Shift, Ctrl,
 * Cmd or Alt), not held down, naming a kind the picker offers.
 */
export function kindForKey(ev: KindKeyEvent | null | undefined, offered: readonly string[]): string {
  if (!ev || ev.isComposing || ev.repeat) return ''
  if (ev.shiftKey || ev.ctrlKey || ev.metaKey || ev.altKey) return ''
  const key = String(ev.key || '')
  if (!/^[A-Za-z]$/.test(key)) return ''
  const letter = key.toUpperCase()
  return (offered || []).find((k) => KIND_KEYS[k] === letter) || ''
}
