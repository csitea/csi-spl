/**
 * Which pane the reader selected last: the middle list or the right topic
 * pane. Owner, 2026-09-25: "whenever the last selected pane was the middle
 * pane ... typing on the omnibox and hitting enter should have created an
 * is_topic=1 msg, not a thread msg with is_topic=0".
 *
 * So an open right pane is not enough to make a send level 2. The right pane
 * takes the line only while it is the pane the reader was last in: opening a
 * topic (replies, a row click, Enter on a card) puts the reader there, and so
 * does a click or focus inside it. A click or focus in the middle moves them
 * back, and the next send starts a new topic. The sidebar, the top bar and a
 * pane divider leave the choice where it was.
 */

export const MIDDLE = 'middle'
export const RIGHT = 'right'

/**
 * The pane an event target sits in, or '' for anywhere that does not choose.
 * @param {unknown} el
 * @returns {'' | 'middle' | 'right'}
 */
export function paneOfTarget(el) {
  const e = /** @type {{ closest?: (s: string) => unknown } | null} */ (el)
  if (!e || typeof e.closest !== 'function') return ''
  if (e.closest('.pane-divider')) return ''
  if (e.closest('aside.live-pane')) return RIGHT
  if (e.closest('.spool-main')) return MIDDLE
  return ''
}

/** A focusin this soon after a navigation key counts as the reader's own move. */
export const KEY_NAV_MS = 1000

/**
 * SPL-996: only the READER chooses a pane. Measured on prd t1 (2026-09-27,
 * #spool-hub-mobile, n=4): four follow-ups typed while a topic was open each
 * became a new topic, because something the reader did not mean as "go back
 * to the middle" had set it:
 *   - a pointerdown on a pane's SCROLLBAR (dragging the middle list to read)
 *   - a focusin the app made itself: a card focused on mount for a #hash, a
 *     row focused after an edit, a restore after `/`. Those are not a choice.
 * So a pointerdown counts unless it lands on the target's scrollbar, and a
 * focusin counts only right after a navigation key (Tab, arrows ...) pressed
 * outside a text field - typing and sending in the composer is not one.
 * @param {{ type?: string, onScrollbar?: boolean, keyNavAt?: number, now?: number }} ev
 */
export function eventChoosesPane({ type = '', onScrollbar = false, keyNavAt = 0, now = 0 } = {}) {
  if (type === 'pointerdown') return !onScrollbar
  if (type === 'focusin') return keyNavAt > 0 && now - keyNavAt >= 0 && now - keyNavAt <= KEY_NAV_MS
  return false
}

/**
 * Is a keydown a navigation key pressed outside a text field? Typing (and the
 * Enter that sends) in the composer is not; Tab / arrows / Home / End / F6 on
 * a row or a button are.
 * @param {{ key?: string, target?: unknown }} ev
 */
export function isKeyNav(ev) {
  const key = String((ev && ev.key) || '')
  if (!/^(Tab|Arrow(Up|Down|Left|Right)|Home|End|PageUp|PageDown|F6)$/.test(key)) return false
  const t = /** @type {{ closest?: (s: string) => unknown } | null} */ ((ev && ev.target) || null)
  if (key !== 'Tab' && key !== 'F6' && t && typeof t.closest === 'function' && t.closest('textarea, input, [contenteditable="true"]')) return false
  return true
}

/**
 * A pointerdown on the element's own scrollbar: past its client box, while it
 * scrolls. offsetX/offsetY are relative to the padding edge, clientWidth /
 * clientHeight exclude the bar.
 * @param {{ target?: unknown, offsetX?: number, offsetY?: number }} ev
 */
export function onScrollbar(ev) {
  const el = /** @type {{ clientWidth?: number, clientHeight?: number, scrollWidth?: number, scrollHeight?: number } | null} */ ((ev && ev.target) || null)
  if (!el || typeof el.clientWidth !== 'number' || !el.clientWidth) return false
  const x = Number(ev.offsetX), y = Number(ev.offsetY)
  const vbar = (el.scrollHeight || 0) > (el.clientHeight || 0) && x >= el.clientWidth
  const hbar = (el.scrollWidth || 0) > el.clientWidth && y >= (el.clientHeight || 0)
  return Boolean(vbar || hbar)
}

/**
 * Does the open right pane take the next Omnibox line? Only when it is open
 * and the middle was not the pane selected last. Unknown ('') counts as the
 * pane: a topic opened from a `?topic=` URL is the newest thing on screen.
 * @param {{ paneOpen?: boolean, lastPane?: string }} [opts]
 */
export function paneTakesLine({ paneOpen = false, lastPane = '' } = {}) {
  return Boolean(paneOpen) && lastPane !== MIDDLE
}
