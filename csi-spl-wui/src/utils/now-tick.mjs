// The topic pane's 1 Hz clock (composables/useNowTick.ts), without Vue.
//
// It runs while the pane is open AND the tab is visible. A hidden tab paints
// nothing, yet every tick re-rendered the open thread (each card's "sent 12s"
// label) for as long as the tab sat in the background (CLE-35075). On the way
// back to visible the clock reads Date.now() at once, so the first painted
// frame is exactly what the old always-on clock would have shown.

/**
 * @param {{
 *   set: (ms: number) => void,
 *   now?: () => number,
 *   doc?: { visibilityState?: string, addEventListener?: Function, removeEventListener?: Function } | null,
 *   every?: (fn: () => void, ms: number) => unknown,
 *   cancel?: (id: unknown) => void,
 * }} deps
 */
export function createNowTick(deps) {
  const now = deps.now || (() => Date.now())
  const doc = deps.doc === undefined ? (typeof document === 'undefined' ? null : document) : deps.doc
  const every = deps.every || ((fn, ms) => setInterval(fn, ms))
  const cancel = deps.cancel || ((id) => clearInterval(/** @type {any} */ (id)))
  let enabled = false
  let id = null

  const hidden = () => Boolean(doc && doc.visibilityState === 'hidden')

  function stop() {
    if (id != null) {
      cancel(id)
      id = null
    }
  }

  function sync() {
    if (!enabled || hidden()) return stop()
    deps.set(now())
    if (id == null) id = every(() => { deps.set(now()) }, 1000)
  }

  const onVisibility = () => sync()
  if (doc && doc.addEventListener) doc.addEventListener('visibilitychange', onVisibility)

  return {
    /** on: the pane is open */
    enable(on) {
      enabled = Boolean(on)
      sync()
    },
    running: () => id != null,
    dispose() {
      enabled = false
      stop()
      if (doc && doc.removeEventListener) doc.removeEventListener('visibilitychange', onVisibility)
    },
  }
}
