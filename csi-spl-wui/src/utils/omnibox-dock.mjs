/**
 * Topic c6994436, lane B: the Omnibox at the BOTTOM on tablet and desktop.
 *
 * Settings -> Behaviour (`composer_position`, a hub pref like SPL-976
 * submit_key): `top` (the default, today's layout) keeps the one
 * MessageComposer in the top bar; `bottom` moves that same instance (a
 * Teleport, so the draft, the picked files and the pickers survive the move)
 * into the dock under the MIDDLE pane only - never over the rail, never
 * under the thread pane. Phones (<= 820 px) ignore it: their composer is
 * docked at the bottom already (SPL-991/1005), in either setting.
 */

export const DEFAULT_POSITION = 'top'

/** The element the bottom Omnibox is teleported into (layouts/default.vue). */
export const DOCK_ID = 'spl-omnibox-dock'

/**
 * An unknown, null or missing value is the default: nobody's view changes
 * until they choose.
 * @param {unknown} v
 * @returns {'top' | 'bottom'}
 */
export function parsePosition(v) {
  return v === 'bottom' ? 'bottom' : DEFAULT_POSITION
}

/**
 * Is the Omnibox in the bottom dock right now?
 * @param {{ position?: unknown, phone?: boolean }} [opts]
 */
export function omniboxAtBottom({ position, phone = false } = {}) {
  return !phone && parsePosition(position) === 'bottom'
}

/**
 * The grip drags the box's free edge: the bottom edge in the top bar, the
 * TOP edge in the bottom dock - so there dragging UP grows it.
 * @param {{ startH: number, startY: number, y: number, bottom?: boolean, min?: number, max: number }} o
 */
export function resizeHeight({ startH, startY, y, bottom = false, min = 36, max }) {
  const delta = bottom ? startY - y : y - startY
  return Math.min(max, Math.max(min, Math.round(startH + delta)))
}

/**
 * The tallest the box may get. In the top bar it may reach the bottom of the
 * window (it grows over the page). In the dock it pushes the middle pane up
 * instead, so it stops at 60% of what is under the top bar and the feed
 * keeps its header and a few rows.
 * @param {{ innerHeight: number, topBarH?: number, bottom?: boolean }} o
 */
export function omniboxMaxHeight({ innerHeight, topBarH = 58, bottom = false }) {
  if (bottom) return Math.max(36, Math.floor((innerHeight - topBarH) * 0.6))
  return Math.max(36, Math.floor(innerHeight - topBarH - 8))
}

/*
 * Owner, t1 (2026-10-02 21:28Z): "Add handle to the omnibox on mobile to be
 * able to drag to the top of the screen and to the right". On a phone the
 * docked box carries a grip; a drag snaps it to one of three places, kept per
 * browser (like the Flow's Mine / All):
 *   bottom - full width on the bottom edge (the default, SPL-991)
 *   top    - full width right under the top bar; the panes start under it
 *   right  - the bottom-RIGHT corner, about 4/5 of the width: the thumb of
 *            the holding hand reaches the field, Attach and Send, and a strip
 *            of the feed stays readable on the left
 */
export const PHONE_POSITIONS = Object.freeze(['bottom', 'top', 'right'])
export const DEFAULT_PHONE_POSITION = 'bottom'
/** localStorage key: the place is this browser's, not the account's. */
export const PHONE_POSITION_KEY = 'spool.omnibox-phone-pos'

/**
 * @param {unknown} v
 * @returns {'bottom' | 'top' | 'right'}
 */
export function parsePhonePosition(v) {
  return PHONE_POSITIONS.includes(/** @type {string} */ (v)) ? /** @type {'bottom' | 'top' | 'right'} */ (v) : DEFAULT_PHONE_POSITION
}

/** Below this many px of travel the grip was tapped, not dragged (a tap opens the menu). */
export const DRAG_SLOP = 8

/**
 * Where a released drag lands: the upper 40% of the screen is the top, the
 * right 40% of the rest is the right corner, anything else the bottom. Read
 * from the finger, not from the box, so the same gesture lands the same way
 * from every starting place.
 * @param {{ x: number, y: number, width: number, height: number }} o
 * @returns {'bottom' | 'top' | 'right'}
 */
export function snapPhonePosition({ x, y, width, height }) {
  if (y < height * 0.4) return 'top'
  if (x > width * 0.6) return 'right'
  return 'bottom'
}

/**
 * Was it a drag at all?
 * @param {{ dx: number, dy: number, slop?: number }} o
 */
export function isPhoneDrag({ dx, dy, slop = DRAG_SLOP }) {
  return Math.hypot(dx, dy) >= slop
}
