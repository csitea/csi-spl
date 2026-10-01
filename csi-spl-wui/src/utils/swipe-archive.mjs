// CLE-77906 (owner, t1 topic 73c5d695): "Both from the thread messages (AK
// cards view) and from the topic messages (AK topic view), one should be able
// to archive a topic by sliding to the right on mobile."
//
// The swipe state machine for components/MessageCard.vue. A finger (or pen)
// that moves mostly RIGHT drags the card; past the threshold, lifting archives
// the topic (the menu's Archive: same permission, same "Archived · Undo"
// snackbar). Anything else cancels and the card snaps back:
//   - the first SWIPE_LOCK_PX of travel decide the axis: mostly vertical is a
//     scroll (the browser keeps it, the card never moves), mostly left is
//     nothing (a left swipe is not ours);
//   - a lift short of the threshold, or a drag back under it, cancels;
//   - a second finger, a pointercancel or a mouse never start one.
// Pure (no DOM), so the unit test drives it.

/** travel before the axis is decided; also the long-press slop (touch-ui.mjs) */
export const SWIPE_LOCK_PX = 10
/** lifting past this archives: 35% of the card, kept between these bounds */
export const SWIPE_MIN_PX = 80
export const SWIPE_MAX_PX = 140
export const SWIPE_RATIO = 0.35
/** the snap back / slide out (MessageCard's transition is 0.18 s) */
export const SWIPE_SETTLE_MS = 200
/** horizontal must beat vertical by this factor to lock as a swipe */
export const SWIPE_AXIS_RATIO = 1.2

/** The archive threshold for a card `width` px wide. */
export function swipeThresholdPx(width) {
  const w = Number(width) || 0
  return Math.round(Math.min(SWIPE_MAX_PX, Math.max(SWIPE_MIN_PX, w * SWIPE_RATIO)))
}

/** Only a finger or a pen swipes; a mouse keeps the desktop card as it was. */
function isTouchLike(pointerType) {
  return pointerType === 'touch' || pointerType === 'pen'
}

/**
 * @param {{ width: () => number, rtl?: () => boolean,
 *   onMove?: (dx: number, armed: boolean) => void,
 *   onLock?: () => void,
 *   onCommit: () => void, onCancel?: () => void }} opts
 */
export function createSwipe(opts) {
  /** 'idle' | 'pending' (finger down, axis not decided) | 'swiping' | 'off' (not ours until lift) */
  let state = 'idle'
  let x0 = 0
  let y0 = 0
  let dx = 0
  let threshold = SWIPE_MIN_PX
  let swallow = false
  const sign = () => (opts.rtl && opts.rtl() ? -1 : 1)

  function reset(cancelled) {
    const was = state
    state = 'idle'
    dx = 0
    if (was === 'swiping' && cancelled && opts.onCancel) opts.onCancel()
  }

  return {
    /** @param {{ pointerType?: string, clientX: number, clientY: number, isPrimary?: boolean }} ev */
    down(ev) {
      swallow = false
      if (state === 'swiping') return reset(true)
      if (!isTouchLike(ev.pointerType) || ev.isPrimary === false) {
        state = 'idle'
        return
      }
      state = 'pending'
      x0 = ev.clientX
      y0 = ev.clientY
      dx = 0
      threshold = swipeThresholdPx(opts.width())
    },
    /** @param {{ clientX: number, clientY: number, isPrimary?: boolean }} ev */
    move(ev) {
      if (ev.isPrimary === false) return
      if (state !== 'pending' && state !== 'swiping') return
      const rx = (ev.clientX - x0) * sign()
      const ry = ev.clientY - y0
      if (state === 'pending') {
        if (Math.hypot(rx, ry) < SWIPE_LOCK_PX) return
        if (rx > 0 && rx > Math.abs(ry) * SWIPE_AXIS_RATIO) {
          state = 'swiping'
          if (opts.onLock) opts.onLock()
        } else {
          state = 'off'
          return
        }
      }
      dx = Math.max(0, rx)
      if (opts.onMove) opts.onMove(dx, dx >= threshold)
    },
    /** the finger lifted: archive when past the threshold */
    up() {
      if (state !== 'swiping') return reset(false)
      const commit = dx >= threshold
      swallow = true
      state = 'idle'
      dx = 0
      if (commit) opts.onCommit()
      else if (opts.onCancel) opts.onCancel()
    },
    cancel() {
      reset(true)
    },
    /** true once after a swipe: the click the lift sends is not a tap */
    takeClick() {
      const was = swallow
      swallow = false
      return was
    },
    get swiping() { return state === 'swiping' },
    get dx() { return dx },
    get threshold() { return threshold },
  }
}
