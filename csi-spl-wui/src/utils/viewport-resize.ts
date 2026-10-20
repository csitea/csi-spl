// One window `resize` listener for every card that measures itself
// (MessageCard's clip), run once per animation frame (CLE-35075).
//
// Each clipped card added its own listener, and a window drag fires resize
// at frame rate: N listeners x 2 getComputedStyle + scrollHeight reads per
// event. Now the first subscriber adds the one listener, a burst of resize
// events in one frame runs every subscriber once, before that frame paints,
// and the last unsubscribe removes the listener again.
//
// perf round 4 W5: the tab's ONE viewport source. A `visual` subscriber
// (useKeyboardInset's --kb-inset) also hears the visualViewport's resize and
// scroll - the on-screen keyboard moves only the VISUAL viewport - through the
// same passive listeners and the same frame, so it runs at most once per
// frame. A visualViewport-only frame runs the visual subscribers alone: the
// keyboard sliding does not re-measure every clipped card. The resize steps
// fire before that frame's animation-frame callbacks, so the rAF lands in the
// SAME frame: --kb-inset is set before the keyboard frame paints.

const PASSIVE = { passive: true }

type ViewportTarget = { addEventListener: (...a: unknown[]) => void, removeEventListener: (...a: unknown[]) => void }
type ViewportSubscribeOpts = { visual?: boolean, initial?: boolean }
type ViewportEnv = { win?: (ViewportTarget & { visualViewport?: unknown }) | null, vv?: ViewportTarget | null, frame?: (fn: () => void) => unknown }
type ViewportResize = { subscribe(fn: () => void, opts?: ViewportSubscribeOpts): () => void, size(): number }

export function createViewportResize(env: ViewportEnv = {}): ViewportResize {
  const win: (ViewportTarget & { visualViewport?: unknown }) | null = env.win === undefined
    ? (typeof window === 'undefined' ? null : (window as unknown as ViewportTarget & { visualViewport?: unknown }))
    : env.win
  const vv: ViewportTarget | null = env.vv === undefined ? ((win && win.visualViewport) as ViewportTarget | null | undefined) || null : env.vv
  const frame = env.frame || ((fn: () => void) => (typeof requestAnimationFrame === 'function' ? requestAnimationFrame(fn) : setTimeout(fn, 16)))
  const subs = new Set<() => void>()
  const visual = new Set<() => void>()
  let queued = false
  let windowDirty = false

  function run() {
    queued = false
    const fns = windowDirty ? [...subs, ...visual] : [...visual]
    windowDirty = false
    for (const fn of fns) {
      try { fn() } catch { /* one card must not stop the others */ }
    }
  }
  function queue(fromWindow: boolean) {
    if (fromWindow) windowDirty = true
    if (queued) return
    queued = true
    frame(run)
  }
  function onResize() { queue(true) }
  function onVisual() { queue(false) }

  /**
   * opts.visual: also on visualViewport resize + scroll; opts.initial: run it
   * in the next frame too. Returns the off function.
   */
  function subscribe(fn: () => void, opts: ViewportSubscribeOpts = {}): () => void {
    if (!win) return () => {}
    const w = win
    const set = opts.visual ? visual : subs
    if (!subs.size && !visual.size) w.addEventListener('resize', onResize, PASSIVE)
    if (set === visual && !visual.size && vv) {
      vv.addEventListener('resize', onVisual, PASSIVE)
      vv.addEventListener('scroll', onVisual, PASSIVE)
    }
    set.add(fn)
    if (opts.initial) queue(set === subs)
    return () => {
      if (!set.delete(fn)) return
      if (set === visual && !visual.size && vv) {
        vv.removeEventListener('resize', onVisual)
        vv.removeEventListener('scroll', onVisual)
      }
      if (!subs.size && !visual.size) w.removeEventListener('resize', onResize)
    }
  }

  return { subscribe, size: () => subs.size + visual.size }
}

let shared: ViewportResize | null = null
/** The tab's one instance. */
export function onViewportResize(fn: () => void, opts?: ViewportSubscribeOpts): () => void {
  if (!shared) shared = createViewportResize()
  return shared.subscribe(fn, opts)
}
