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
 * instead; owner, t1 8de4c254 (msg a80f71d8): "it should be possible to
 * resize the Omnibox up to the top button section", so there it stops just
 * under the pane's header row (`topBarH`, see topButtonsBottom), less the
 * dock's own `chrome` (its padding and the rows around the field).
 * @param {{ innerHeight: number, topBarH?: number, bottom?: boolean, chrome?: number }} o
 */
export function omniboxMaxHeight({ innerHeight, topBarH = 58, bottom = false, chrome = 0 }) {
  if (bottom) return Math.max(36, Math.floor(innerHeight - topBarH - chrome))
  return Math.max(36, Math.floor(innerHeight - topBarH - 8))
}

/**
 * Where the "top button section" ends (owner, t1 8de4c254): the bottom of
 * the header row right under the top bar in the pane above the box (the
 * topic header: back, title, the three view buttons; the section tabs on
 * the list), else the top bar's bottom. A resized box grows up to it, never
 * over it.
 * @param {Document} doc
 * @param {Element} box  the composer; skipped when it covers that row
 * @returns {number} px from the top of the window
 */
export function topButtonsBottom(doc, box) {
  const bar = doc.querySelector('[data-test=top-bar]')
  const barBottom = bar ? bar.getBoundingClientRect().bottom : 0
  const r = box.getBoundingClientRect()
  const y = barBottom + 1
  const hit = doc.elementsFromPoint(r.left + r.width / 2, y).find((e) => !box.contains(e))
  const row = hit && hit.closest('header, .feed-header, .sidebar-rail')
  const rr = row && row.getBoundingClientRect()
  return rr && rr.top <= y && rr.bottom > y ? rr.bottom : barBottom
}

/* the grip and the size handle stand 16 px over the box's free edge
   (OmniboxGrip.vue); at the limit they end on the header row, not over it */
const GRIP_REACH_PX = 16

/**
 * The tallest a resized phone-dock field may be at the bottom: from the
 * box's bottom edge up to the top button section, less the box's own
 * chrome (box height minus field height) and the grip's reach.
 * @param {{ boxBottom: number, boxH: number, fieldH: number, limitTop: number }} o
 */
export function dockFieldMax({ boxBottom, boxH, fieldH, limitTop }) {
  return Math.max(0, Math.floor(boxBottom - limitTop - GRIP_REACH_PX - (boxH - fieldH)))
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
const DEFAULT_PHONE_POSITION = 'bottom'
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
const DRAG_SLOP = 8

/**
 * Where a released drag lands: the upper 40% of the screen is the top, the
 * right 40% of the rest is the right corner, anything else the bottom. Read
 * from the finger, not from the box, so the same gesture lands the same way
 * from every starting place. The screen is what the eye sees: the visual
 * viewport (`left` / `top` its offset in the layout viewport the finger's
 * clientX / clientY are in, `width` / `height` its size), so a zoomed page
 * (SPL-2829) snaps by the same thirds as an unzoomed one.
 * @param {{ x: number, y: number, width: number, height: number, left?: number, top?: number }} o
 * @returns {'bottom' | 'top' | 'right'}
 */
export function snapPhonePosition({ x, y, width, height, left = 0, top = 0 }) {
  if (y - top < height * 0.4) return 'top'
  if (x - left > width * 0.6) return 'right'
  return 'bottom'
}

/**
 * The screen a drag snaps against (SPL-2829): the visual viewport when the
 * browser has one, else the window.
 * @param {{ innerWidth: number, innerHeight: number, visualViewport?: { width: number, height: number, offsetLeft: number, offsetTop: number } | null }} win
 * @returns {{ width: number, height: number, left: number, top: number }}
 */
export function visibleScreen(win) {
  const vv = win.visualViewport
  if (vv && vv.width > 0 && vv.height > 0) return { width: vv.width, height: vv.height, left: vv.offsetLeft || 0, top: vv.offsetTop || 0 }
  return { width: win.innerWidth, height: win.innerHeight, left: 0, top: 0 }
}

/**
 * Was it a drag at all?
 * @param {{ dx: number, dy: number, slop?: number }} o
 */
export function isPhoneDrag({ dx, dy, slop = DRAG_SLOP }) {
  return Math.hypot(dx, dy) >= slop
}

/*
 * Owner, t1 (2026-10-02 21:53Z): "This is good too, but it should be possible
 * to resize it". The size is kept per browser next to the place, one value
 * per place, as a SHARE so it follows a rotation and the keyboard:
 *   bottom / top - the field's height, a share of the room under the top bar
 *                  (above the keyboard): 0 = one line that grows with the text
 *                  (the default); "large" is HEIGHT_MAX (half). At the
 *                  bottom a drag may go up to the top button section
 *                  (owner, t1 8de4c254: dockFieldMax); at the top it stops
 *                  at HEIGHT_MAX so half the screen stays readable
 *   right        - the corner box's width, a share of the screen width: at
 *                  least WIDTH_MIN_PX (field, Attach and Send still fit), at
 *                  most the width less WIDTH_GAP_PX (a strip of the feed
 *                  stays tappable on the left); unset = min(84vw, 360px)
 * The CSS repeats the same bounds (MessageComposer.vue), so a share stored on
 * a bigger screen can never cover a smaller one.
 */
export const PHONE_SIZE_KEY = 'spool.omnibox-phone-size'
export const HEIGHT_MAX = 0.5
/* a dragged height may go up to the whole room; the px cap under the top
   button section (dockFieldMax, --dock-field-max) is what really stops it */
const HEIGHT_LIMIT = 1
const WIDTH_MIN_PX = 280
const WIDTH_GAP_PX = 48
/** Less than this many px over one line and a dragged field is one line again. */
const HEIGHT_SNAP_PX = 16
export const SIZE_PRESETS = Object.freeze(['small', 'medium', 'large'])
const HEIGHT_PRESET = Object.freeze({ small: 0, medium: 0.25, large: HEIGHT_MAX })
/* small at 390 px: 281 px, the field still shows a few words */
const WIDTH_PRESET = Object.freeze({ small: 0.72, medium: 0.84, large: 1 })

const round3 = (n) => Math.round(n * 1000) / 1000

/**
 * The stored sizes; anything unreadable is dropped (that place's default).
 * @param {unknown} raw  the localStorage string
 * @returns {{ bottom?: number, top?: number, right?: number }}
 */
export function parsePhoneSize(raw) {
  /** @type {any} */
  let o = {}
  try { o = typeof raw === 'string' && raw ? JSON.parse(raw) : {} } catch { o = {} }
  /** @type {{ bottom?: number, top?: number, right?: number }} */
  const out = {}
  if (!o || typeof o !== 'object') return out
  for (const p of /** @type {const} */ (['bottom', 'top'])) {
    const v = o[p]
    if (typeof v === 'number' && Number.isFinite(v)) out[p] = round3(Math.min(HEIGHT_LIMIT, Math.max(0, v)))
  }
  const w = o.right
  if (typeof w === 'number' && Number.isFinite(w) && w > 0) out.right = round3(Math.min(1, w))
  return out
}

/**
 * The share a preset stands for in a place.
 * @param {'bottom' | 'top' | 'right'} pos
 * @param {'small' | 'medium' | 'large'} preset
 */
export function presetSize(pos, preset) {
  return pos === 'right' ? WIDTH_PRESET[preset] : HEIGHT_PRESET[preset]
}

/**
 * Which preset the current size is, if any (the menu ticks it). Unset is the
 * place's default: small for a height (one line), medium for the width.
 * @param {'bottom' | 'top' | 'right'} pos
 * @param {number | undefined} v
 * @returns {'small' | 'medium' | 'large' | null}
 */
export function sizePreset(pos, v) {
  if (v == null) return pos === 'right' ? 'medium' : 'small'
  for (const p of /** @type {const} */ (['small', 'medium', 'large'])) {
    if (Math.abs(presetSize(pos, p) - v) < 0.02) return p
  }
  return null
}

/**
 * A drag on the size handle, on the box's free edge: away from the screen
 * edge the box hangs on is bigger - UP at the bottom, DOWN at the top, LEFT
 * in the corner (its width).
 * @param {{ pos: 'bottom' | 'top' | 'right', start: number, dx: number, dy: number, room: number, oneLine?: number, max?: number }} o
 *   start - the field's height (the box's width in the corner) in px when the
 *   finger went down; room - what a share is of (the px under the top bar
 *   above the keyboard, or the screen width); oneLine - the one-line field;
 *   max - the largest height share (HEIGHT_MAX unless the caller measured
 *   the room up to the top button section)
 * @returns {number} the new share
 */
export function resizePhoneSize({ pos, start, dx, dy, room, oneLine = 44, max = HEIGHT_MAX }) {
  if (!(room > 0)) return 0
  if (pos === 'right') {
    const hi = (room - WIDTH_GAP_PX) / room
    const lo = Math.min(WIDTH_MIN_PX / room, hi)
    return round3(Math.min(hi, Math.max(lo, (start - dx) / room)))
  }
  const px = start + (pos === 'top' ? dy : -dy)
  if (px < oneLine + HEIGHT_SNAP_PX) return 0
  return round3(Math.min(Math.min(HEIGHT_LIMIT, max), px / room))
}
