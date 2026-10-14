// csi-spl-wui/src/utils/tree-drag.mjs
//
// SPL-1873 (owner HUM-10, t1 1a9a14b6 msg 32d5ea87: "enable drag and drop
// aka re-order of files within folders in the qto file explorer"): a file
// tree row (UiFileTree) drags onto the gap between two rows, or onto a
// folder row to go into it.
//
// Pointer events, not HTML5 drag, as move-drag.mjs: one path for mouse and
// touch. A mouse lifts the row after TREE_DRAG_START_PX of travel. A finger
// holds LONG_PRESS_MS first: the hold opens the row's menu (touch-ui.mjs, a
// phone has no right-click), and a finger that then moves lifts the row
// instead, so the menu still opens without a drag. A finger that moves
// before the hold is scrolling. Pure: the Node tests drive it with fake
// timers.

import { LONG_PRESS_MS, LONG_PRESS_SLOP_PX } from './touch-ui.mjs'

/** A mouse / pen press becomes a drag after this much travel, px. */
export const TREE_DRAG_START_PX = 5
/** The band at a row's top and bottom that means "the gap", of its height (the middle of a folder = into it). */
export const TREE_DROP_EDGE = 0.3

/**
 * Where a drop over a row lands, from the pointer's y in the row's box:
 * the top band = before it, the bottom band = after it, the middle = into it
 * (a folder). A place the caller refuses falls back to the nearest one it
 * takes; null = none.
 *
 * @param {number} y
 * @param {{ top: number, height: number }} box
 * @param {{ before: boolean, after: boolean, into: boolean }} ok
 * @returns {'before' | 'after' | 'into' | null}
 */
export function dropWhere(y, box, ok) {
  if (!(box.height > 0) || !Number.isFinite(y)) return null
  const f = (y - box.top) / box.height
  const edge = ok.into ? TREE_DROP_EDGE : 0.5
  if (f < edge && ok.before) return 'before'
  if (f >= 1 - edge && ok.after) return 'after'
  if (ok.into) return 'into'
  if (ok.before && f < 0.5) return 'before'
  if (ok.after && f >= 0.5) return 'after'
  return null
}

/**
 * The row's previous (dir -1) or next (dir 1) sibling in the visible rows:
 * the nearest row at the same depth that way, before a row above that depth
 * (the end of the folder). -1 = none.
 *
 * @param {{ depth: number }[]} rows
 * @param {number} i
 * @param {-1 | 1} dir
 */
export function siblingAt(rows, i, dir) {
  const d = rows[i]?.depth
  if (d === undefined) return -1
  for (let j = i + dir; j >= 0 && j < rows.length; j += dir) {
    if (rows[j].depth < d) return -1
    if (rows[j].depth === d) return j
  }
  return -1
}

/** createTreeDrag's options with every default filled in. */
function treeDragOptions(opts) {
  return {
    startPx: opts.startPx ?? TREE_DRAG_START_PX,
    holdMs: opts.holdMs ?? LONG_PRESS_MS,
    slopPx: opts.slopPx ?? LONG_PRESS_SLOP_PX,
    setTimer: opts.setTimer ?? ((fn, ms) => setTimeout(fn, ms)),
    clearTimer: opts.clearTimer ?? ((id) => clearTimeout(/** @type {any} */ (id))),
  }
}

/**
 * A press not lifted yet, after the pointer moved d px (pure): 'end' = a
 * finger swiped before its hold (the list scrolls), or moved after a hold
 * on a row that does not drag; 'lift' = a mouse travelled far enough, or a
 * held finger moved; else 'wait'.
 *
 * @param {{ state: string, touch: boolean, drag: boolean }} g
 * @param {number} d
 * @param {number} startPx
 * @param {number} slopPx
 */
function pressedStep(g, d, startPx, slopPx) {
  if (g.state === 'pressed' && !g.touch) return d >= startPx ? 'lift' : 'wait'
  if (d <= slopPx) return 'wait'
  return g.state === 'held' && g.drag ? 'lift' : 'end'
}

/**
 * The row gesture. The host feeds it pointer events and gets:
 *   onHold(x, y)   - a finger held still (the host opens the row's menu)
 *   onStart(x, y)  - the row lifted (mouse: travel; touch: a move after the hold)
 *   onMove(x, y)   - every move while lifted
 *   onDrop(x, y)   - released while lifted
 *   onCancel()     - Escape, pointercancel, or the host tore it down
 * `takeClick()` is true exactly once after a hold or a lift, so the click
 * the browser sends on release does not also select the row.
 *
 * @param {{ onHold: (x: number, y: number) => void, onStart: (x: number, y: number) => void,
 *   onMove: (x: number, y: number) => void, onDrop: (x: number, y: number) => void, onCancel: () => void,
 *   startPx?: number, holdMs?: number, slopPx?: number,
 *   setTimer?: (fn: () => void, ms: number) => unknown, clearTimer?: (id: unknown) => void }} opts
 */
export function createTreeDrag(opts) {
  const { startPx, holdMs, slopPx, setTimer, clearTimer } = treeDragOptions(opts)
  /** @type {{ state: 'idle' | 'pressed' | 'held' | 'lifted', pointerId: number, touch: boolean, drag: boolean,
   *   x0: number, y0: number, timer: unknown, swallow: boolean }} */
  const g = { state: 'idle', pointerId: -1, touch: false, drag: false, x0: 0, y0: 0, timer: null, swallow: false }

  function stopTimer() {
    if (g.timer !== null) clearTimer(g.timer)
    g.timer = null
  }
  /** back to idle; true when the row was lifted, so the host hears the end */
  function settle() {
    stopTimer()
    const was = g.state
    g.state = 'idle'
    return was === 'lifted'
  }
  function lift(x, y) {
    g.state = 'lifted'
    g.swallow = true
    opts.onStart(x, y)
    opts.onMove(x, y)
  }

  return {
    get state() { return g.state },
    /**
     * A press on a row; drag = the row may be dragged (else a finger's hold only opens the menu).
     * @param {{ pointerId: number, pointerType?: string, button?: number, isPrimary?: boolean, clientX: number, clientY: number }} ev
     * @param {boolean} drag
     */
    down(ev, drag) {
      settle()
      g.swallow = false
      g.touch = ev.pointerType === 'touch' || ev.pointerType === 'pen'
      if (ev.isPrimary === false || (!g.touch && (ev.button ?? 0) !== 0) || (!g.touch && !drag)) return
      g.state = 'pressed'
      g.pointerId = ev.pointerId
      g.drag = drag
      g.x0 = ev.clientX
      g.y0 = ev.clientY
      if (g.touch) {
        g.timer = setTimer(() => {
          g.timer = null
          g.state = 'held'
          g.swallow = true
          opts.onHold(g.x0, g.y0)
        }, holdMs)
      }
    },
    /** @param {{ pointerId: number, clientX: number, clientY: number }} ev */
    move(ev) {
      if (ev.pointerId !== g.pointerId || g.state === 'idle') return
      if (g.state === 'lifted') return opts.onMove(ev.clientX, ev.clientY)
      const next = pressedStep(g, Math.hypot(ev.clientX - g.x0, ev.clientY - g.y0), startPx, slopPx)
      if (next === 'lift') lift(ev.clientX, ev.clientY)
      else if (next === 'end') settle()
    },
    /** @param {{ pointerId: number, clientX: number, clientY: number }} ev */
    up(ev) {
      if (ev.pointerId !== g.pointerId) return
      if (settle()) opts.onDrop(ev.clientX, ev.clientY)
    },
    cancel() {
      if (settle()) opts.onCancel()
    },
    /** a finger held: the host stops the page scrolling under the drag */
    get holding() { return g.state === 'held' || (g.state === 'lifted' && g.touch) },
    takeClick() {
      const s = g.swallow
      g.swallow = false
      return s
    },
  }
}
