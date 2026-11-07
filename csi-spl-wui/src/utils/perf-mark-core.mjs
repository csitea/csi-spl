// csi-spl-wui/src/utils/perf-mark-core.mjs
//
// The measurement points of the real-user timing (spec 066, lane L6): the
// half the entry chunk needs, because live-ws.mjs imports perfMark. The points
// MessageComposer and LiveFeed call are in perf-mark.mjs, in their own chunks.
//
// Why a module of its own: a static import of perf-rum.mjs would pull the
// whole collector in (spec 5: "the collector is NOT in the initial chunk").
// So this file holds only what must run before the collector loads - the
// queue and M1 - and perf-rum.mjs, loaded after onNuxtReady, attaches itself
// as the sink and brings the pairing of the later timings (M3, M4, M5) with
// it. With RUM off (cnf perf.rum_enabled) every entry point is one boolean test.
//
// Fire-and-forget (spec 4.0): nothing here throws, awaits or forces a layout
// on a hot path. NO PERSONAL DATA (spec 4.2): msg ids stay in memory to pair
// a send with its row; a sample carries only the metric, the time and enums.

const EARLY_MAX = 32

const RAIL_SEL = '[data-testid^="sidebar-tab-"]'

let sink = null

let onFlag = null

const early = []

/** Shared with the sink's pairing (perf-rum.mjs perfFeedPair). */
const st = { landed: false, navAt: -1, sends: [], bound: new Map(), keys: 0, delivered: '', railStop: null, routed: false }

const now = () => (globalThis.performance ? globalThis.performance.now() : Date.now())

/** RUM is on for this build (runtime config perfRum, read once). */
export function perfOn() {
  if (onFlag === null) {
    try {
      onFlag = String(globalThis.__NUXT__?.config?.public?.perfRum) === '1'
    } catch {
      onFlag = false
    }
  }
  return onFlag
}

const live = () => sink !== null || perfOn()

/**
 * Record one timing. Synchronous, never throws, never awaits. Before the
 * collector loads, up to 32 marks wait for it.
 * @returns {boolean} true when the running collector kept the sample
 */
export function perfMark(metric, valueMs, fields) {
  try {
    if (sink) return sink.mark(metric, valueMs, fields) === true
    if (perfOn() && early.length < EARLY_MAX) early.push([metric, valueMs, fields])
  } catch { /* fire and forget */ }
  return false
}

/** perf-rum.mjs: the running collector takes the marks (and what waited). */
export function perfAttach(s) {
  sink = s && typeof s.mark === 'function' ? s : null
  while (sink && early.length) {
    const a = early.shift()
    perfMark(a[0], a[1], a[2])
  }
}

/** Tests only: forget the sink, the queue and every pairing. */
export function perfMarkReset({ on = null } = {}) {
  sink = null
  onFlag = on
  early.length = 0
  Object.assign(st, { landed: false, navAt: -1, keys: 0, delivered: '', railStop: null, routed: false })
  st.sends.length = 0
  st.bound.clear()
}

/** Run fn after the next paint: a frame, then a task (spec 3, M6). */
export function afterPaint(fn) {
  const run = () => { try { fn() } catch { /* fire and forget */ } }
  try {
    const raf = globalThis.requestAnimationFrame
    if (typeof raf === 'function') raf(() => setTimeout(run, 0))
    else setTimeout(run, 0)
  } catch { /* fire and forget */ }
}

/** M1 / M2 `cache`: warm when the document came from the cache, else cold. */
export function perfCache(perf = globalThis.performance) {
  try {
    const nav = perf.getEntriesByType('navigation')[0]
    if (nav && typeof nav.transferSize === 'number') return { cache: nav.transferSize === 0 ? 'warm' : 'cold' }
  } catch { /* no navigation timing */ }
  return undefined
}

/**
 * M1 load_rail: navigation start -> the rail's first tab visible. Watched from
 * the moment this module loads (with the app's first chunk), so the paint is
 * seen even though the collector arrives later. Not timed: a rail already up
 * when this loads (no honest end), and a rail that shows only after the
 * person did something (a tap, a key, a navigation: the phone opens on the
 * feed and the rail is one tap away) - that is not a load.
 */
function watchRail(doc = globalThis.document) {
  try {
    if (!doc || typeof MutationObserver !== 'function' || !perfOn()) return
    const up = () => {
      const el = doc.querySelector(RAIL_SEL)
      return Boolean(el && el.getClientRects().length)
    }
    if (up()) return
    const inputs = ['pointerdown', 'keydown']
    const stop = () => {
      mo.disconnect()
      st.railStop = null
      for (const ev of inputs) doc.removeEventListener(ev, stop, true)
    }
    const mo = new MutationObserver(() => {
      if (!up()) return
      stop()
      const cache = perfCache()
      afterPaint(() => perfMark('load_rail', now(), cache))
    })
    mo.observe(doc.documentElement, { childList: true, subtree: true })
    for (const ev of inputs) doc.addEventListener(ev, stop, true)
    st.railStop = stop
    setTimeout(stop, 60_000)
  } catch { /* fire and forget */ }
}

watchRail()

/** perf-mark.mjs's half: the running collector, or null. */
export function perfSink() {
  return sink
}

export { live as perfLive, now as perfNow, st as perfShared }
