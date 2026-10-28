// csi-spl-wui/src/utils/move-drag.ts
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
const MOVE_TOUCH_SLOP_PX = 10

export type MoveHit = { kind: 'channel' | 'card' | 'topics', id: string, scope: string, ok: boolean, title: string }
type Pt = { pointerId: number, pointerType?: string, button?: number, clientX: number, clientY: number }
export type HandleDrag = { readonly state: 'idle' | 'pressed' | 'lifted' | 'held', down(ev: Pt): boolean, move(ev: Pt): void, up(ev: Pt): void, cancel(): void, takeClick(): boolean }
export type HandleDragOpts = {
  onStart: (x: number, y: number) => void, onMove: (x: number, y: number) => void,
  onDrop: (x: number, y: number) => void, onCancel: () => void, onHold?: () => boolean,
  startPx?: number, holdMs?: number, slopPx?: number,
  setTimer?: (fn: () => void, ms: number) => unknown, clearTimer?: (id: unknown) => void,
}
export type EdgeScroll = { readonly running: boolean, at(x: number, y: number): void, stop(): void }
export type EdgeScrollOpts = {
  box: () => { top: number, bottom: number, scrollBy: (dy: number) => boolean } | null,
  onScroll: (x: number, y: number) => void,
  frame?: (fn: () => void) => unknown, cancelFrame?: (id: unknown) => void,
}

/**
 * What the pointer is over, read from the element under it: the nearest
 * `[data-move-drop]` ancestor whose kind fits the drag - a channel row for a
 * topic, a middle card for a reply. `ok` is the row's own verdict
 * (`data-move-ok`, set by the row from the same rule the hub applies).
 * `scope` (`data-move-scope`) tells apart two rows of one channel in two
 * rail lists (Channels and Flow): only the row under the pointer is lit.
 * null = nothing that takes this drag, so nothing is highlighted.
 */
export function moveHit(el: unknown, drag: { kind?: string } | null | undefined): MoveHit | null {
  const node = el as { closest?: (sel: string) => { dataset?: Record<string, string | undefined> } | null } | null | undefined
  if (!node || typeof node.closest !== 'function' || !drag) return null
  const row = node.closest('[data-move-drop]')
  if (!row) return null
  const ds = row.dataset || {}
  const kind = ds.moveDrop as MoveHit['kind'] | undefined
  // A reply drags onto a topic card (move-v1 §3) or into the topics-list
  // background = PROMOTE to a new topic (8f588edd). A topic card drags onto a
  // channel row (a move, §2) OR onto another topic card (a MERGE, 714c7028).
  const fits = drag.kind === 'message' ? kind === 'card' || kind === 'topics' : kind === 'channel' || kind === 'card'
  if (!fits || !kind || !ds.moveId) return null
  return { kind, id: String(ds.moveId), scope: String(ds.moveScope || ''), ok: ds.moveOk === 'true', title: String(ds.moveTitle || '') }
}

/** Two hits name the same row with the same verdict (no store write for a no-op move). */
export function sameHit(a: MoveHit | null, b: MoveHit | null): boolean {
  if (!a || !b) return a === b
  return a.kind === b.kind && a.id === b.id && a.scope === b.scope && a.ok === b.ok
}

/** createHandleDrag's options with every default filled in. */
function handleDragOptions(opts: HandleDragOpts) {
  return {
    startPx: opts.startPx ?? MOVE_DRAG_START_PX,
    holdMs: opts.holdMs ?? MOVE_TOUCH_HOLD_MS,
    slopPx: opts.slopPx ?? MOVE_TOUCH_SLOP_PX,
    setTimer: opts.setTimer ?? ((fn: () => void, ms: number): unknown => setTimeout(fn, ms)),
    clearTimer: opts.clearTimer ?? ((id: unknown) => clearTimeout(id as ReturnType<typeof setTimeout>)),
  }
}

/**
 * Where a press that has not lifted yet goes after the pointer moved (pure):
 * 'release' = a finger slid past the slop, so it was not holding;
 * 'lift' = a mouse / pen travelled far enough to start the drag; else 'wait'.
 */
function pressedMove(
  g: { touch: boolean, x0: number, y0: number, x: number, y: number },
  cfg: { startPx: number, slopPx: number },
): 'release' | 'lift' | 'wait' {
  const d = Math.hypot(g.x - g.x0, g.y - g.y0)
  if (g.touch) return d > cfg.slopPx ? 'release' : 'wait'
  return d >= cfg.startPx ? 'lift' : 'wait'
}

type HandleDragCfg = ReturnType<typeof handleDragOptions>
/** The gesture so far. x0/y0 = where the press began, x/y = the pointer now. */
type Gesture = {
  state: HandleDrag['state'], pointerId: number, touch: boolean,
  x0: number, y0: number, x: number, y: number, timer: unknown, swallow: boolean,
}

/** A gesture before any press. */
function idleGesture(): Gesture {
  return { state: 'idle', pointerId: -1, touch: false, x0: 0, y0: 0, x: 0, y: 0, timer: null, swallow: false }
}

/** The card lifts: the host hears the start, and the release click is swallowed. */
function liftGesture(g: Gesture, opts: HandleDragOpts) {
  g.state = 'lifted'
  g.swallow = true
  opts.onStart(g.x, g.y)
}

/** Back to idle. True when the card was lifted, so the host hears the end. */
function settleGesture(g: Gesture, cfg: HandleDragCfg) {
  if (g.timer !== null) cfg.clearTimer(g.timer)
  g.timer = null
  const was = g.state
  g.state = 'idle'
  return was === 'lifted'
}

/** A press on the handle: refused while one is down and for a mouse button other than the left. */
function pressDown(g: Gesture, ev: Pt, cfg: HandleDragCfg, holdEnded: () => void): boolean {
  if (g.state !== 'idle') return false
  if (ev.pointerType === 'mouse' && ev.button !== 0) return false
  g.state = 'pressed'
  g.pointerId = ev.pointerId
  g.touch = ev.pointerType === 'touch'
  g.x0 = g.x = ev.clientX
  g.y0 = g.y = ev.clientY
  g.swallow = false
  if (g.touch) g.timer = cfg.setTimer(holdEnded, cfg.holdMs)
  return true
}

/** A move of the pressing pointer: a lifted card follows, a pressed one lifts or releases. */
function pressMove(g: Gesture, ev: Pt, cfg: HandleDragCfg, opts: HandleDragOpts) {
  if (ev.pointerId !== g.pointerId || g.state === 'idle' || g.state === 'held') return
  g.x = ev.clientX
  g.y = ev.clientY
  if (g.state === 'lifted') {
    opts.onMove(g.x, g.y)
    return
  }
  const next = pressedMove(g, cfg)
  if (next === 'release') settleGesture(g, cfg)
  else if (next === 'lift') {
    liftGesture(g, opts)
    opts.onMove(g.x, g.y)
  }
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
 */
export function createHandleDrag(opts: HandleDragOpts): HandleDrag {
  const cfg = handleDragOptions(opts)
  const g = idleGesture()

  /** A finger stayed down for holdMs. */
  function holdEnded() {
    g.timer = null
    if (g.state !== 'pressed') return
    if (!opts.onHold || opts.onHold()) liftGesture(g, opts)
    else {
      g.state = 'held'
      g.swallow = true
    }
  }

  return {
    get state() { return g.state },
    down(ev: Pt) { return pressDown(g, ev, cfg, holdEnded) },
    move(ev: Pt) { pressMove(g, ev, cfg, opts) },
    up(ev: Pt) {
      if (ev.pointerId !== g.pointerId) return
      if (settleGesture(g, cfg)) opts.onDrop(ev.clientX, ev.clientY)
    },
    cancel() {
      if (settleGesture(g, cfg)) opts.onCancel()
    },
    takeClick() {
      const s = g.swallow
      g.swallow = false
      return s
    },
  }
}

// HUM-10 (owner, t1 5a410ad5): "One should be able to drag and drop topics
// into other topics on mobile as well." A phone lifts a topic card with a
// long press on the card itself and drags it with the finger; the list it sits
// in scrolls while the finger is near the list's top or bottom edge.

/** The band at a list edge that scrolls it, px (capped at a third of the list). */
export const MOVE_EDGE_PX = 56
/** The fastest auto-scroll, px per frame (the finger at the very edge). */
export const MOVE_EDGE_MAX_STEP = 16

/**
 * How far the list scrolls this frame for a finger at `y` in a list spanning
 * `top..bottom` (viewport px): negative up, positive down, 0 in the middle.
 * The speed grows the deeper the finger is in the edge band.
 */
export function edgeScrollStep(y: number, top: number, bottom: number, edge = MOVE_EDGE_PX, max = MOVE_EDGE_MAX_STEP): number {
  if (!(bottom > top) || !Number.isFinite(y)) return 0
  const band = Math.min(edge, (bottom - top) / 3)
  if (y < top + band) return -Math.ceil(max * Math.min(1, (top + band - y) / band))
  if (y > bottom - band) return Math.ceil(max * Math.min(1, (y - (bottom - band)) / band))
  return 0
}

/**
 * The auto-scroll loop of one drag. `at(x, y)` feeds the finger and starts
 * the loop; each frame the box from `box()` scrolls by edgeScrollStep and,
 * when it did, `onScroll(x, y)` runs (the rows moved under a finger that did
 * not, so the host re-reads the row under it). `stop()` ends the loop.
 */
export function createEdgeScroll(opts: EdgeScrollOpts): EdgeScroll {
  const frame = opts.frame ?? ((fn: () => void): unknown => requestAnimationFrame(fn))
  const cancelFrame = opts.cancelFrame ?? ((id: unknown) => cancelAnimationFrame(id as number))
  let id: unknown = null
  let x = 0
  let y = 0
  let on = false
  function tick() {
    id = null
    if (!on) return
    const b = opts.box()
    const dy = b ? edgeScrollStep(y, b.top, b.bottom) : 0
    if (dy && b && b.scrollBy(dy)) opts.onScroll(x, y)
    id = frame(tick)
  }
  return {
    get running() { return on },
    at(nx: number, ny: number) {
      x = nx
      y = ny
      if (on) return
      on = true
      id = frame(tick)
    },
    stop() {
      on = false
      if (id !== null) cancelFrame(id)
      id = null
    },
  }
}
