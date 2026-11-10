// csi-spl-wui/src/utils/perf-mark.mjs
//
// The measurement points of the real-user timing (spec 066, lane L6) that the
// composer and LiveFeed call, and the rest from perf-mark-core.mjs, which the
// entry chunk carries. Same rules there: nothing here throws, awaits or forces
// a layout on a hot path, and a sample carries no personal data.

import { afterPaint, perfCache, perfLive as live, perfMark, perfNow as now, perfShared as st, perfSink } from './perf-mark-core.mjs'

export { afterPaint, perfAttach, perfCache, perfMark, perfMarkReset, perfOn } from './perf-mark-core.mjs'

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
    const sink = perfSink()
    if (sink && typeof sink.feed === 'function') sink.feed(st, f, { rows, fresh, shown }, o)
    if (shown && !st.landed) {
      st.landed = true
      const cache = perfCache()
      afterPaint(() => perfMark('load_messages', now(), cache))
    }
  } catch { /* fire and forget */ }
}

/**
 * M4: a message from someone else arrived live and its row is in this feed.
 * `wallNow` is the wall clock (ms) paired with the hub's received_at, as in
 * perf-rum.mjs perfOptions; injectable for tests.
 */
export function perfDelivered(m, { wallNow = () => Date.now() } = {}) {
  try {
    const sink = perfSink()
    if (!sink || typeof sink.deliver !== 'function' || !m || m.pending) return
    const id = String(m.msg_id || '')
    const hubMs = Date.parse(String(m.received_at || ''))
    if (!id || id === st.delivered || !Number.isFinite(hubMs)) return
    st.delivered = id
    afterPaint(() => { const s = perfSink(); if (s) s.deliver(hubMs, wallNow()) })
  } catch { /* fire and forget */ }
}
