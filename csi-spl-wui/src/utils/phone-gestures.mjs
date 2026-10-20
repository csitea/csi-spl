// SPL-2148 (epic SPL-2130, UI suggestion 4): the phone's gestures for the
// desktop keys that are off on a phone (composables/useGlobalKeys.ts). A
// TWO-finger swipe up opens the command palette (the desktop's Ctrl + K).
//
// Why two fingers: one finger is taken everywhere. A one-finger swipe up
// scrolls the page, from the bottom edge it is the phone's own home gesture,
// a one-finger swipe right is Back (utils/mobile-stack.mjs isMobileBackSwipe)
// and a card's swipe archives it. Two fingers moving apart or together are the
// browser's pinch zoom, so the fingers must keep their distance. No other
// gesture in the WUI uses two fingers.

/** Each finger travels up at least this far (px). */
const PALETTE_SWIPE_MIN_DY = 64
/** ... and at most this far sideways (px). */
const PALETTE_SWIPE_MAX_DX = 48
/** The fingers' distance changes at most this much (px): more is a pinch. */
const PALETTE_SWIPE_MAX_SPREAD = 40

/**
 * The start of a palette swipe: exactly two fingers down, else null (a third
 * finger, or one, is not ours).
 * @param {ArrayLike<{ identifier: number, clientX: number, clientY: number }> | null | undefined} touches
 * @returns {{ id: number, x: number, y: number }[] | null}
 */
export function paletteSwipeStart(touches) {
  if (!touches || touches.length !== 2) return null
  return [touches[0], touches[1]].map((t) => ({ id: t.identifier, x: t.clientX, y: t.clientY }))
}

/**
 * Does a two-finger gesture open the palette? Both fingers went up
 * PALETTE_SWIPE_MIN_DY, mostly vertically, and kept their distance.
 * @param {{ id: number, x: number, y: number }[] | null} start paletteSwipeStart's points
 * @param {{ id: number, x: number, y: number }[] | null} end the same fingers' last points
 */
export function isPaletteSwipe(start, end) {
  if (!start || start.length !== 2 || !end || end.length !== 2) return false
  const moved = start.map((s) => {
    const e = end.find((p) => p.id === s.id)
    return e ? { dx: Math.abs(e.x - s.x), dy: s.y - e.y, e } : null
  })
  if (moved.some((m) => !m)) return false
  const up = moved.every((m) => m.dy >= PALETTE_SWIPE_MIN_DY && m.dx <= PALETTE_SWIPE_MAX_DX && m.dy > m.dx * 1.5)
  if (!up) return false
  const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y)
  return Math.abs(dist(moved[0].e, moved[1].e) - dist(start[0], start[1])) <= PALETTE_SWIPE_MAX_SPREAD
}
