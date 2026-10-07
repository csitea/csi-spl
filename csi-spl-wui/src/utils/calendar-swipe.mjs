// spec 106 T002: the phone calendar's gestures, pure. CalendarPhone.vue (T004)
// feeds a touch track in; this says what it was (spec 4.3, S2-2, S4 Q3):
//
// - directional lock: once the finger moves dy >= 10 px before dx >= 16 px
//   the gesture is a vertical scroll until it ends; dx >= 16 px with
//   dx > 1.5 dy locks it to a horizontal page turn;
// - a horizontal track turns the page: left = `next`, right = `prev`
//   (mirrored in rtl), unless it started in the 24 px edge zone on the Back
//   side, where it is `back` and the stack keeps it (no `stack.swipe.claim()`);
// - a tap is < 8 px of travel and < 300 ms; a still finger held > 400 ms
//   is 097's hold-to-drag.
//
// Names carry "calSwipe" because Nuxt auto-imports every utils export.

/** dy that locks a gesture to vertical scrolling (if dx has not reached CAL_SWIPE_LOCK_DX) */
export const CAL_SWIPE_LOCK_DY = 10
/** dx that locks a gesture to a page turn (when also > 1.5 dy) */
export const CAL_SWIPE_LOCK_DX = 16
/** a horizontal track this long on release turns the page (the stack's own MOBILE_SWIPE_MIN_DX) */
export const CAL_SWIPE_TURN_DX = 64
/** the Back zone on the leading edge (S4 Q3: 24 px, not 16, clears the OS's ~20 px) */
export const CAL_SWIPE_EDGE_PX = 24
/** a tap moves less than this ... */
export const CAL_SWIPE_TAP_PX = 8
/** ... and is released before this */
export const CAL_SWIPE_TAP_MS = 300
/** a still finger held longer than this lifts the event (097 hold-to-drag) */
export const CAL_SWIPE_HOLD_MS = 400

/**
 * @typedef {{ x: number, y: number, t?: number }} CalSwipePoint
 * @typedef {{ points: CalSwipePoint[], width: number, rtl?: boolean }} CalSwipeTrack
 * @typedef {'none' | 'x' | 'y'} CalSwipeLock
 */

/**
 * The lock after the finger reaches `p` from `p0`, given the lock so far:
 * once set it holds until the touch ends. Vertical wins a tie (S2-2).
 * @param {CalSwipePoint} p0
 * @param {CalSwipePoint} p
 * @param {CalSwipeLock} [lock]
 * @returns {CalSwipeLock}
 */
export function calSwipeLock(p0, p, lock = 'none') {
  if (lock !== 'none') return lock
  const dx = Math.abs(p.x - p0.x)
  const dy = Math.abs(p.y - p0.y)
  if (dy >= CAL_SWIPE_LOCK_DY) return 'y'
  if (dx >= CAL_SWIPE_LOCK_DX && dx > 1.5 * dy) return 'x'
  return 'none'
}

/**
 * The lock a whole track ends with, walked point by point: the order the
 * thresholds were crossed decides, not only where the finger ended.
 * @param {CalSwipePoint[]} points
 * @returns {CalSwipeLock}
 */
export function calSwipeTrackLock(points) {
  /** @type {CalSwipeLock} */
  let lock = 'none'
  for (const p of points || []) lock = calSwipeLock(points[0], p, lock)
  return lock
}

/**
 * Does a touch starting at `x0` begin in the Back edge zone? The leading
 * edge: x <= 24 in ltr, x >= width - 24 in rtl.
 * @param {number} x0
 * @param {number} width
 * @param {boolean} [rtl]
 */
export function calSwipeInEdge(x0, width, rtl = false) {
  return rtl ? x0 >= width - CAL_SWIPE_EDGE_PX : x0 <= CAL_SWIPE_EDGE_PX
}

/**
 * Should the calendar call `stack.swipe.claim()` at touchend? Yes, unless
 * the touch started in the Back edge zone (9.4 #1): there the shell's Back
 * swipe keeps working.
 * @param {number} x0
 * @param {number} width
 * @param {boolean} [rtl]
 */
export function calSwipeClaims(x0, width, rtl = false) {
  return !calSwipeInEdge(x0, width, rtl)
}

/**
 * One finished touch track: `next` / `prev` turn the period, `back` leaves
 * it to the stack's Back, `none` is a scroll, a tap, a short or diagonal
 * drift. In rtl the directions and the edge mirror.
 * @param {CalSwipeTrack} track
 * @returns {'next' | 'prev' | 'back' | 'none'}
 */
export function calSwipeClassify(track) {
  const pts = track && Array.isArray(track.points) ? track.points : []
  if (pts.length < 2 || !(track.width > 0)) return 'none'
  if (calSwipeTrackLock(pts) !== 'x') return 'none'
  const p0 = pts[0]
  const p1 = pts[pts.length - 1]
  const fwd = track.rtl ? p0.x - p1.x : p1.x - p0.x
  if (Math.abs(fwd) < CAL_SWIPE_TURN_DX) return 'none'
  if (fwd < 0) return 'next'
  return calSwipeInEdge(p0.x, track.width, track.rtl) ? 'back' : 'prev'
}

/**
 * Was the track a tap (tap-to-add on empty time, S2-2)? < 8 px of travel at
 * every point and released < 300 ms after it started.
 * @param {CalSwipePoint[]} points with `t` in ms
 */
export function calSwipeIsTap(points) {
  if (!points || points.length === 0) return false
  const p0 = points[0]
  const far = points.some((p) => Math.hypot(p.x - p0.x, p.y - p0.y) >= CAL_SWIPE_TAP_PX)
  const dwell = Number(points[points.length - 1].t) - Number(p0.t)
  return !far && dwell >= 0 && dwell < CAL_SWIPE_TAP_MS
}

/**
 * Is the finger, still down at `now`, a hold (097 hold-to-drag)? It has not
 * left the tap slop and has been down > 400 ms.
 * @param {CalSwipePoint[]} points with `t` in ms
 * @param {number} now ms
 */
export function calSwipeIsHold(points, now) {
  if (!points || points.length === 0) return false
  const p0 = points[0]
  const far = points.some((p) => Math.hypot(p.x - p0.x, p.y - p0.y) >= CAL_SWIPE_TAP_PX)
  return !far && Number(now) - Number(p0.t) > CAL_SWIPE_HOLD_MS
}
