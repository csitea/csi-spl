// csi-spl-wui/src/utils/perf-mark.mjs
//
// The measurement points of the real-user timing (spec 066, lane L6): the
// small half that MessageComposer, LiveFeed and live-ws.mjs import.
//
// Why a module of its own: those three sit in the initial chunk, and a static
// import of perf-rum.mjs would pull the whole collector in with them (spec 5:
// "the collector is NOT in the initial chunk"). So this file holds only what
// must run before the collector loads - the queue, the starts, M1 and M2 -
// and perf-rum.mjs, loaded after onNuxtReady, attaches itself as the sink and
// brings the pairing of the later timings (M3, M4, M5) with it. With RUM off
// (cnf perf.rum_enabled) every entry point is one boolean test.
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

/** M6: one keydown in ten in the composer (the first included), to the next paint after it. */
export function perfKeydown(eventTs) {
  try {
    if (!live() || st.keys++ % 10) return
    const t0 = Number(eventTs) > 0 ? Number(eventTs) : now()
    afterPaint(() => perfMark('type_next_paint', now() - t0))
  } catch { /* fire and forget */ }
}

/** M3 start: the composer submitted a message. */
export function perfSendStart() {
  try {
    if (!live()) return
    st.sends.push(now())
    if (st.sends.length > 8) st.sends.shift()
  } catch { /* fire and forget */ }
}

/** M5 start: a navigation began; the page load's first view is behind us. */
export function perfNavStart() {
  try {
    if (!live()) return
    st.navAt = now()
    st.landed = true
    if (st.railStop) st.railStop()
  } catch { /* fire and forget */ }
}

/** M5: a navigation to another page (not a #hash, not the same URL) starts a switch. Once per app. */
export function perfWatchRouter(router) {
  try {
    if (st.routed || !live() || !router || typeof router.beforeEach !== 'function') return
    st.routed = true
    const page = (r) => String((r && r.fullPath) || '').split('#')[0]
    router.beforeEach((to, from) => { if (page(to) !== page(from)) perfNavStart() })
  } catch { /* fire and forget */ }
}

/** One feed's own memory (one per LiveFeed instance). */
export function perfFeedState() {
  return { key: null, born: true, sawLoading: false }
}

/**
 * LiveFeed's rows changed. M2 load_messages is timed here: the first view of
 * the page load shows rows (or its empty state, after loading). The sink
 * pairs the rest - M3 send_ack, M5 switch_view - once it has loaded.
 * @param {ReturnType<typeof perfFeedState>} f
 * @param {{ rows: any[], loading: boolean, key: string, path?: string, thread?: boolean, own: (m: any) => boolean }} o
 */
export function perfFeed(f, o) {
  try {
    if (!live()) return
    const fresh = o.key !== f.key
    if (fresh) {
      f.born = f.key === null
      f.key = o.key
      f.sawLoading = false
    }
    if (o.loading) f.sawLoading = true
    const rows = Array.isArray(o.rows) ? o.rows : []
    const shown = !o.loading && (rows.length > 0 || f.sawLoading)
    if (sink && typeof sink.feed === 'function') sink.feed(st, f, rows, fresh, shown, o)
    if (shown && !st.landed) {
      st.landed = true
      const cache = perfCache()
      afterPaint(() => perfMark('load_messages', now(), cache))
    }
  } catch { /* fire and forget */ }
}

/** M4: a message from someone else arrived live and its row is in this feed. */
export function perfDelivered(m) {
  try {
    if (!sink || typeof sink.deliver !== 'function' || !m || m.pending) return
    const id = String(m.msg_id || '')
    const hubMs = Date.parse(String(m.received_at || ''))
    if (!id || id === st.delivered || !Number.isFinite(hubMs)) return
    st.delivered = id
    afterPaint(() => sink && sink.deliver(hubMs, Date.now()))
  } catch { /* fire and forget */ }
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
