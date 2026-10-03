// CLE-77906 (owner, t1 topic 73c5d695): "Both from the thread messages (AK
// cards view) and from the topic messages (AK topic view), one should be able
// to archive a topic by sliding to the right on mobile."
// HUM-10 (owner, t1 topic 2d09e9c2, 2026-10-03): "Let's change the swipe left
// to do the archiving and let's change the swipe right to actually show the
// right-click menu."
//
// The swipe state machine for components/MessageCard.vue. A finger (or pen)
// that moves mostly sideways drags the card; past the threshold, lifting
// commits the direction it went:
//   - LEFT  ('archive') archives the topic (the menu's Archive: same
//     permission, same "Archived · Undo" snackbar);
//   - RIGHT ('menu') opens the card's menu, the one a right-click opens.
// HUM-10 (owner, t1 topics 6fc56905 / 3e073a95, 2026-10-03): "On mobile in
// the reply/thread messages view, it should be possible to hide a
// message/card by just swiping to the left. That would be just hide, not
// archive, not delete." So in the topic view a REPLY's LEFT is 'hide'
// (swipeLeftAction); the topic starter keeps 'archive' and is never hidden.
// Anything else cancels and the card snaps back:
//   - the first SWIPE_LOCK_PX of travel decide the axis: mostly vertical is a
//     scroll (the browser keeps it, the card never moves); a direction the
//     card does not offer (canLeft / canRight) is nothing - a right swipe from
//     the phone's Back zone (swipeInBackZone) stays the shell's Back;
//   - a lift short of the threshold, or a drag back under it, cancels;
//   - a second finger, a pointercancel or a mouse never start one.
// In rtl both directions mirror. Pure (no DOM), so the unit test drives it.

import { MOBILE_SWIPE_EDGE_RATIO } from './mobile-stack.mjs'

/** travel before the axis is decided; also the long-press slop (touch-ui.mjs) */
export const SWIPE_LOCK_PX = 10
/** lifting past this commits: 35% of the card, kept between these bounds */
export const SWIPE_MIN_PX = 80
export const SWIPE_MAX_PX = 140
export const SWIPE_RATIO = 0.35
/** the snap back / slide out (MessageCard's transition is 0.18 s) */
export const SWIPE_SETTLE_MS = 200
/** horizontal must beat vertical by this factor to lock as a swipe */
export const SWIPE_AXIS_RATIO = 1.2

/** The commit threshold for a card `width` px wide. */
export function swipeThresholdPx(width) {
  const w = Number(width) || 0
  return Math.round(Math.min(SWIPE_MAX_PX, Math.max(SWIPE_MIN_PX, w * SWIPE_RATIO)))
}

/** Only a finger or a pen swipes; a mouse keeps the desktop card as it was. */
function isTouchLike(pointerType) {
  return pointerType === 'touch' || pointerType === 'pen'
}

/**
 * Does a finger down at `x` start in the phone's swipe-right Back zone (the
 * start half of a `width` px screen, isMobileBackSwipe's rule)? Such a right
 * swipe is the shell's Back, never the card's.
 */
export function swipeInBackZone(x, width, rtl = false) {
  if (!(width > 0)) return false
  const start = rtl ? width - x : x
  return start <= width * MOBILE_SWIPE_EDGE_RATIO
}

/**
 * What a card's LEFT swipe does, or null for nothing:
 *   - the topic starter (a topic card, or the topic's opening message in the
 *     topic view) archives when the viewer may archive it - and is NEVER
 *     hidden, whatever else holds;
 *   - a reply in the topic view hides (only on this device: not archive,
 *     not delete);
 *   - anything else (a reply outside the topic view) is not a left swipe.
 * @param {{ swipeOn: boolean, starter: boolean, mayArchive: boolean, inTopicPane: boolean }} c
 * @returns {'archive' | 'hide' | null}
 */
export function swipeLeftAction(c) {
  if (!c || !c.swipeOn) return null
  if (c.starter) return c.mayArchive ? 'archive' : null
  return c.inTopicPane ? 'hide' : null
}

/**
 * The direction a move of (rx, ry) from (x0, y0) locks to, or null: mostly
 * vertical, or a direction the card does not offer, is not a swipe.
 * @returns {'archive' | 'hide' | 'menu' | null}
 */
function lockDir(opts, rx, ry, x0, y0) {
  if (Math.abs(rx) <= Math.abs(ry) * SWIPE_AXIS_RATIO) return null
  if (rx < 0) {
    if (opts.leftDir) return opts.leftDir()
    return !opts.canLeft || opts.canLeft() ? 'archive' : null
  }
  return opts.canRight && opts.canRight(x0, y0) ? 'menu' : null
}

/**
 * @param {{ width: () => number, rtl?: () => boolean,
 *   canLeft?: () => boolean,
 *   leftDir?: () => 'archive' | 'hide' | null,
 *   canRight?: (x: number, y: number) => boolean,
 *   onMove?: (dx: number, armed: boolean, dir: 'archive' | 'hide' | 'menu') => void,
 *   onLock?: (dir: 'archive' | 'hide' | 'menu') => void,
 *   onCommit: (dir: 'archive' | 'hide' | 'menu', x: number, y: number) => void,
 *   onCancel?: () => void }} opts
 * `dx` is the travel (>= 0) in the swipe's direction; no canRight, no menu.
 * `leftDir`, when given, decides the left swipe (swipeLeftAction) in place
 * of `canLeft` (which only ever offers 'archive').
 */
export function createSwipe(opts) {
  /** 'idle' | 'pending' (finger down, axis not decided) | 'swiping' | 'off' (not ours until lift) */
  let state = 'idle'
  let x0 = 0
  let y0 = 0
  /** where the finger is now: the menu opens there */
  let at = { x: 0, y: 0 }
  let dx = 0
  /** @type {'archive' | 'hide' | 'menu'} */
  let dir = 'archive'
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
      at = { x: x0, y: y0 }
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
        const locked = lockDir(opts, rx, ry, x0, y0)
        if (!locked) return void (state = 'off')
        dir = locked
        state = 'swiping'
        if (opts.onLock) opts.onLock(dir)
      }
      at = { x: ev.clientX, y: ev.clientY }
      dx = Math.max(0, dir === 'menu' ? rx : -rx)
      if (opts.onMove) opts.onMove(dx, dx >= threshold, dir)
    },
    /** the finger lifted: commit when past the threshold */
    up() {
      if (state !== 'swiping') return reset(false)
      const commit = dx >= threshold
      swallow = true
      state = 'idle'
      dx = 0
      if (commit) opts.onCommit(dir, at.x, at.y)
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
    get dir() { return dir },
    get threshold() { return threshold },
  }
}
