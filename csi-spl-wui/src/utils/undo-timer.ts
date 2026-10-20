// CLE-77871 (owner, t1 topic f20c6052: "the snack bar should work on mobile as
// well"): the auto-dismiss clock of the "<what> · Undo" snackbar
// (components/UndoSnackbar.vue - Archived, Deleted, Moved).
//
// The desktop window is short (0.7 s for archive / delete, owner) and HOLDS
// while the mouse is over it or focus is inside it. A phone has neither: no
// hover before the tap, so the snackbar was gone before a thumb reached Undo.
// On a touch UI the window is at least UNDO_TOUCH_MIN_MS, and it holds while a
// finger is down on it. Pure (timers injected) so the unit test drives it.

/** Touch: the snackbar stays at least this long (>= 5 s is the touch norm). */
export const UNDO_TOUCH_MIN_MS: number = 6000

/** A note with no Undo (a move that cannot be undone) stays this long. */
export const UNDO_NOTE_MS: number = 3000

/** The window for `duration` ms on this UI; 0 = the caller owns timing. */
export function undoWindowMs(duration: number, { touch = false, undo = true }: { touch?: boolean, undo?: boolean } = {}): number {
  const ms = Number(duration) || 0
  if (ms <= 0) return 0
  return touch && undo ? Math.max(ms, UNDO_TOUCH_MIN_MS) : ms
}

/** True when the primary pointer is coarse (a phone, a tablet). Not
    `(hover: none)`: a desktop with no pointer device (a kiosk, headless
    Chrome) reports that too. A finger on the snackbar still switches it
    to the touch window (touched). */
export function isTouchUi(win: Window | undefined = typeof window === 'undefined' ? undefined : window): boolean {
  const mm = win && typeof win.matchMedia === 'function' ? win.matchMedia : null
  if (!mm) return false
  try {
    return Boolean(mm.call(win, '(pointer: coarse)').matches)
  } catch {
    return false
  }
}

export type UndoTimer = {
  arm(): void
  hold(reason?: string): void
  release(reason?: string): void
  touched(): void
  stop(): void
  windowMs(): number
  readonly armed: boolean
  readonly held: boolean
}

/**
 * The snackbar clock. `hold(reason)` stops it (hover / focus / touch, each
 * its own reason, so a mouse leaving while focus stays inside does not
 * restart it); the last `release` re-arms the FULL window. `touched()` makes
 * every later window the touch one (a tap on a UI that matchMedia read as
 * mouse-only, e.g. a touch laptop).
 */
export function createUndoTimer({ duration, touch = false, undo = true, onExpire, set = setTimeout, clear = clearTimeout as (id: unknown) => void }: {
  duration: number
  touch?: boolean
  undo?: boolean
  onExpire: () => void
  set?: (fn: () => void, ms: number) => unknown
  clear?: (id: unknown) => void
}): UndoTimer {
  let timer: unknown = null
  let isTouch = Boolean(touch)
  const holds = new Set<string>()
  const stop = () => { if (timer !== null) { clear(timer); timer = null } }
  const windowMs = () => undoWindowMs(duration, { touch: isTouch, undo })
  function arm() {
    stop()
    const ms = windowMs()
    if (ms > 0 && holds.size === 0) timer = set(() => { timer = null; onExpire() }, ms)
  }
  return {
    arm,
    hold(reason = 'hover') { holds.add(reason); stop() },
    release(reason = 'hover') { if (holds.delete(reason) && holds.size === 0) arm() },
    touched() { isTouch = true },
    stop,
    windowMs,
    get armed() { return timer !== null },
    get held() { return holds.size > 0 },
  }
}
