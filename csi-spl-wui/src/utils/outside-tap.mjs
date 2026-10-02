// csi-spl-wui/src/utils/outside-tap.mjs
//
// Owner, t1 topic e3e9ca61 (on a phone): "whenever I click somewhere else,
// the snack bar and the omnibar should disappear." A snackbar or the expanded
// phone dock that only a tap ON it can close reads as frozen: the attach
// notice inside the dock had no close, no timeout, and a tap on the feed left
// it (and the 40%-tall box) up.
//
// One rule for all of them: a pointerdown anywhere outside the element's own
// roots closes it. Listened in the CAPTURE phase so a card or pane that stops
// propagation cannot swallow it, and never preventDefault-ed, so the tap still
// does what it was for (opens the card, presses the button).
//
// Pure ES module (the document is injected), so the unit suite runs it under
// bare `node`.

import { MOBILE_STACK_QUERY } from './mobile-stack.mjs'

/** The phone / touch media query (SPL-989's one breakpoint, or a finger). */
export const PHONE_OR_TOUCH_QUERY = `${MOBILE_STACK_QUERY}, (pointer: coarse)`

/**
 * True when `target` lies inside none of `roots`. A missing target (a
 * pointerdown on the document itself) is outside; a missing root is skipped.
 *
 * @param {any} target
 * @param {Array<any>} roots
 */
export function isOutsideTap(target, roots) {
  if (!target || typeof target !== 'object') return true
  for (const r of roots) {
    if (r && typeof r.contains === 'function' && r.contains(target)) return false
  }
  return true
}

/**
 * Call `onOutside(ev)` for every pointerdown outside `getRoots()`. Returns
 * the remover.
 *
 * @param {{ addEventListener: Function, removeEventListener: Function }} doc
 * @param {() => Array<any>} getRoots
 * @param {(ev: any) => void} onOutside
 */
export function onOutsideTap(doc, getRoots, onOutside) {
  const handler = (ev) => {
    if (isOutsideTap(ev && ev.target, getRoots())) onOutside(ev)
  }
  doc.addEventListener('pointerdown', handler, true)
  return () => doc.removeEventListener('pointerdown', handler, true)
}

/** True on a phone-size or touch UI. False when matchMedia is missing. */
export function isPhoneOrTouch(win = typeof window === 'undefined' ? undefined : window) {
  const mm = win && typeof win.matchMedia === 'function' ? win.matchMedia : null
  if (!mm) return false
  try {
    return Boolean(mm.call(win, PHONE_OR_TOUCH_QUERY).matches)
  } catch {
    return false
  }
}
