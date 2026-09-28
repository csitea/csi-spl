// One window `resize` listener for every card that measures itself
// (MessageCard's clip), run once per animation frame (CLE-35075).
//
// Each clipped card added its own listener, and a window drag fires resize
// at frame rate: N listeners x 2 getComputedStyle + scrollHeight reads per
// event. Now the first subscriber adds the one listener, a burst of resize
// events in one frame runs every subscriber once, before that frame paints,
// and the last unsubscribe removes the listener again.

/**
 * @param {{ win?: { addEventListener: Function, removeEventListener: Function } | null, frame?: (fn: () => void) => unknown }} [env]
 */
export function createViewportResize(env = {}) {
  const win = env.win === undefined ? (typeof window === 'undefined' ? null : window) : env.win
  const frame = env.frame || ((fn) => (typeof requestAnimationFrame === 'function' ? requestAnimationFrame(fn) : setTimeout(fn, 16)))
  const subs = new Set()
  let queued = false

  function run() {
    queued = false
    for (const fn of [...subs]) {
      try { fn() } catch { /* one card must not stop the others */ }
    }
  }
  function onResize() {
    if (queued) return
    queued = true
    frame(run)
  }

  /** @param {() => void} fn  @returns {() => void} off */
  function subscribe(fn) {
    if (!win) return () => {}
    if (!subs.size) win.addEventListener('resize', onResize, { passive: true })
    subs.add(fn)
    return () => {
      if (!subs.delete(fn)) return
      if (!subs.size) win.removeEventListener('resize', onResize)
    }
  }

  return { subscribe, size: () => subs.size }
}

let shared = null
/** The tab's one instance. */
export function onViewportResize(fn) {
  if (!shared) shared = createViewportResize()
  return shared.subscribe(fn)
}
