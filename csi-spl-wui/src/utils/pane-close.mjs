// csi-spl-wui/src/utils/pane-close.mjs
//
// SPL-2552 (owner HUM-10, t1 7af14523 msg 5e6f0db8): "Shift + W on Desktop
// should close the right most pane - similarly to how Ctrl + W closes a tab".
// Shift + W runs the X of the rightmost pane on screen, the same click as the
// pane's own X: the topic pane (live, channel or the operator console), a
// page's side pane (a user, the calendar hours), a section page's way out,
// then the search results in the left panel. With no such X on screen, the
// base view, it does nothing. Never while typing (a field types its capital
// W), never on a phone, never over a menu or a dialog; Ctrl / Cmd + W stays
// the browser's. The listener is composables/useGlobalKeys.ts.

/** The X of every closable pane (UiCloseButton renders one of each pair). */
export const PANE_CLOSE_X = [
  'button.topic-close',
  'button[data-test="users-pane-close"]',
  'button[data-test="hours-panel-close"]',
  'button[data-test="section-close"]',
  'button[data-testid="side-search-close"]',
].join(', ')

const TYPING = 'input, textarea, select, [contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"], [role="textbox"], [role="combobox"]'

/** Is the caret in a text field? Shift + W types there. */
export function inTextField(el) {
  if (!el || typeof el.closest !== 'function') return false
  if (el.isContentEditable) return true
  return Boolean(el.closest(TYPING))
}

/**
 * Is this keydown Shift + W (the W by its key or its place, for non-Latin
 * layouts)? Not with Ctrl, Cmd or Alt, not while composing, not a repeat:
 * holding the keys closes one pane, not every pane.
 *
 * @param {{ key?: string, code?: string, shiftKey?: boolean, ctrlKey?: boolean, metaKey?: boolean,
 *           altKey?: boolean, isComposing?: boolean, repeat?: boolean } | null | undefined} ev
 */
export function isCloseKey(ev) {
  if (!ev || !ev.shiftKey || ev.ctrlKey || ev.metaKey || ev.altKey) return false
  if (ev.isComposing || ev.repeat) return false
  return ev.key === 'W' || ev.key === 'w' || ev.code === 'KeyW'
}

/**
 * The rightmost of the given X buttons: the one whose pane starts furthest
 * right; on a tie the later one in the page. null for none.
 *
 * @template T
 * @param {readonly T[]} xs
 * @param {(x: T) => number} leftOf the left edge of the pane the X closes
 * @returns {T | null}
 */
export function rightmostClose(xs, leftOf) {
  let best = null
  let bestLeft = -Infinity
  for (const x of xs || []) {
    const left = Number(leftOf(x))
    if (!Number.isFinite(left) || left < bestLeft) continue
    best = x
    bestLeft = left
  }
  return best
}
