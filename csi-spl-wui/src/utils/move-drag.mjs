// csi-spl-wui/src/utils/move-drag.mjs
//
// SPL-1134 (specs/045 §3.9): the drag HANDLE of a movable card. The owner:
// hovering "the left-most side of the panel containing the topic" shows a
// drag affordance on "the first 3 mm", a drag starts from there only, and
// while it is dragged "1..1 highlighted channel" is where it will drop.
//
// Pointer events, not HTML5 drag: one code path for mouse, pen and touch, no
// native drag image, and nothing a link inside the row can hijack (the
// native link drag that swallowed SPL-1034's reorder). Pure: the Node tests
// drive the state machine with fake timers and fake elements.

/** The handle strip, px: ~3 mm at 96 dpi. */
export const MOVE_HANDLE_PX = 12
/** A mouse / pen press becomes a drag after this much travel. */
export const MOVE_DRAG_START_PX = 4
/** A finger on the handle lifts the card after this hold (a phone opens the picker instead). */
export const MOVE_TOUCH_HOLD_MS = 350
/** A finger that moved more than this before the hold ended was not holding. */
export const MOVE_TOUCH_SLOP_PX = 10

/**
 * What the pointer is over, read from the element under it: the nearest
 * `[data-move-drop]` ancestor whose kind fits the drag - a channel row for a
 * topic, a middle card for a reply. `ok` is the row's own verdict
 * (`data-move-ok`, set by the row from the same rule the hub applies).
 * `scope` (`data-move-scope`) tells apart two rows of one channel in two
 * rail lists (Channels and Flow): only the row under the pointer is lit.
 * null = nothing that takes this drag, so nothing is highlighted.
 *
 * @param {{ closest?: (sel: string) => any } | null | undefined} el
 * @param {{ kind?: string } | null | undefined} drag
 * @returns {{ kind: 'channel' | 'card', id: string, scope: string, ok: boolean, title: string } | null}
 */
export function moveHit(el, drag) {
  if (!el || typeof el.closest !== 'function' || !drag) return null
  const row = el.closest('[data-move-drop]')
  if (!row) return null
  const ds = row.dataset || {}
  const kind = ds.moveDrop
  const want = drag.kind === 'message' ? 'card' : 'channel'
  if (kind !== want || !ds.moveId) return null
  return { kind, id: String(ds.moveId), scope: String(ds.moveScope || ''), ok: ds.moveOk === 'true', title: String(ds.moveTitle || '') }
}

/** Two hits name the same row with the same verdict (no store write for a no-op move). */
export function sameHit(a, b) {
  if (!a || !b) return a === b
  return a.kind === b.kind && a.id === b.id && a.scope === b.scope && a.ok === b.ok
}

/**
 * The handle's gesture. The host feeds it pointer events and gets:
 *   onStart(x, y)  - the drag lifted (mouse / pen: 4 px of travel; touch: a hold)
 *   onMove(x, y)   - every move while lifted
 *   onDrop(x, y)   - released while lifted
 *   onCancel()     - Escape, pointercancel, or the host tore it down
 *   onHold()       - a finger held still; return true to lift the card,
 *                    false when the host did something else (a phone opens
 *                    the Move to channel picker: its rail is not on screen)
 * `takeClick()` is true exactly once after a lift or a hold, so the click
 * the browser sends on release does not also open the topic.
 *
 * @param {{ onStart: (x: number, y: number) => void, onMove: (x: number, y: number) => void,
 *   onDrop: (x: number, y: number) => void, onCancel: () => void, onHold?: () => boolean,
 *   startPx?: number, holdMs?: number, slopPx?: number,
 *   setTimer?: (fn: () => void, ms: number) => unknown, clearTimer?: (id: unknown) => void }} opts
 */
export function createHandleDrag(opts) {
  const startPx = opts.startPx ?? MOVE_DRAG_START_PX
  const holdMs = opts.holdMs ?? MOVE_TOUCH_HOLD_MS
  const slopPx = opts.slopPx ?? MOVE_TOUCH_SLOP_PX
  const setTimer = opts.setTimer ?? ((fn, ms) => setTimeout(fn, ms))
  const clearTimer = opts.clearTimer ?? ((id) => clearTimeout(/** @type {any} */ (id)))
  /** @type {'idle' | 'pressed' | 'lifted' | 'held'} */
  let state = 'idle'
  let pointerId = -1
  let touch = false
  let x0 = 0
  let y0 = 0
  let x = 0
  let y = 0
  /** @type {unknown} */
  let timer = null
  let swallow = false

  function stopTimer() {
    if (timer !== null) clearTimer(timer)
    timer = null
  }
  function lift() {
    state = 'lifted'
    swallow = true
    opts.onStart(x, y)
  }

  return {
    get state() { return state },
    /** @param {{ pointerId: number, pointerType?: string, button?: number, clientX: number, clientY: number }} ev */
    down(ev) {
      if (state !== 'idle') return false
      if (ev.pointerType === 'mouse' && ev.button !== 0) return false
      state = 'pressed'
      pointerId = ev.pointerId
      touch = ev.pointerType === 'touch'
      x0 = x = ev.clientX
      y0 = y = ev.clientY
      swallow = false
      if (touch) {
        timer = setTimer(() => {
          timer = null
          if (state !== 'pressed') return
          if (!opts.onHold || opts.onHold()) lift()
          else {
            state = 'held'
            swallow = true
          }
        }, holdMs)
      }
      return true
    },
    /** @param {{ pointerId: number, clientX: number, clientY: number }} ev */
    move(ev) {
      if (ev.pointerId !== pointerId || state === 'idle' || state === 'held') return
      x = ev.clientX
      y = ev.clientY
      if (state === 'lifted') {
        opts.onMove(x, y)
        return
      }
      const d = Math.hypot(x - x0, y - y0)
      if (touch) {
        if (d > slopPx) {
          stopTimer()
          state = 'idle'
        }
        return
      }
      if (d >= startPx) {
        lift()
        opts.onMove(x, y)
      }
    },
    /** @param {{ pointerId: number, clientX: number, clientY: number }} ev */
    up(ev) {
      if (ev.pointerId !== pointerId) return
      stopTimer()
      const was = state
      state = 'idle'
      if (was === 'lifted') opts.onDrop(ev.clientX, ev.clientY)
    },
    cancel() {
      stopTimer()
      const was = state
      state = 'idle'
      if (was === 'lifted') opts.onCancel()
    },
    takeClick() {
      const s = swallow
      swallow = false
      return s
    },
  }
}
