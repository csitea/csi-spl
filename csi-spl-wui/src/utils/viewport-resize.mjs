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

/**
 * @param {{ win?: { addEventListener: Function, removeEventListener: Function, visualViewport?: unknown } | null, vv?: { addEventListener: Function, removeEventListener: Function } | null, frame?: (fn: () => void) => unknown }} [env]
 */
export function createViewportResize(env = {}) {
  const win = env.win === undefined ? (typeof window === 'undefined' ? null : window) : env.win
  const vv = env.vv === undefined ? (win && win.visualViewport) || null : env.vv
  const frame = env.frame || ((fn) => (typeof requestAnimationFrame === 'function' ? requestAnimationFrame(fn) : setTimeout(fn, 16)))
  const subs = new Set()
  const visual = new Set()
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
  function queue(fromWindow) {
    if (fromWindow) windowDirty = true
    if (queued) return
    queued = true
    frame(run)
  }
  function onResize() { queue(true) }
  function onVisual() { queue(false) }

  /**
   * @param {() => void} fn
   * @param {{ visual?: boolean, initial?: boolean }} [opts] visual: also on
   *   visualViewport resize + scroll; initial: run it in the next frame too
   * @returns {() => void} off
   */
  function subscribe(fn, opts = {}) {
    if (!win) return () => {}
    const set = opts.visual ? visual : subs
    if (!subs.size && !visual.size) win.addEventListener('resize', onResize, PASSIVE)
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
      if (!subs.size && !visual.size) win.removeEventListener('resize', onResize)
    }
  }

  return { subscribe, size: () => subs.size + visual.size }
}

let shared = null
/** The tab's one instance. */
export function onViewportResize(fn, opts) {
  if (!shared) shared = createViewportResize()
  return shared.subscribe(fn, opts)
}
