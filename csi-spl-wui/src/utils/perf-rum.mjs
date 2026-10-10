// csi-spl-wui/src/utils/perf-rum.mjs
//
// The real-user timing collector (spec 066, lane L5): what people FEEL, timed
// in their own browser and sent to POST /v1/perf/samples (hub, lane L2).
//
// Pure: no Vue, no Nuxt. The plugin (plugins/perf-rum.client.ts) imports it
// after onNuxtReady and calls startPerfRum; until then, and whenever RUM is
// off, perfMark() is a no-op.
//
// FIRE-AND-FORGET (spec 4.0, owner Q4: "if for some reason the logging doesn't
// work, it should not mess with the whole thing"):
//   - perfMark() pushes into a ring buffer and returns a boolean at once; its
//     body is wrapped in try/catch, so it never throws into a UI path
//   - the POST is never awaited by UI code; a rejected, slow (> 5 s, aborted)
//     or non-2xx send DROPS the batch: no retry, no queue growth. Three
//     failures in a row stop the tab until the next load
//   - the buffer holds 500 samples; a full buffer drops the oldest and the
//     next batch reports how many were dropped
//   - at most 300 samples per tab per hour (spec 4 sampling)
//   - pagehide / hidden: what is left goes in a final sendBeacon
//
// NO PERSONAL DATA (spec 4.2): a sample is built from a fixed list of fields,
// each an enum or a bounded number. The caller cannot add a field, and an
// out-of-set value drops the sample rather than send it. session_id is a
// random uuid per TAB, held in this module's memory only.
//
// THE MEASUREMENT POINTS (lane L6): MessageComposer, LiveFeed and live-ws.mjs
// mark through perf-mark.mjs (small, in the initial chunk); startPerfRum
// attaches this collector there as the sink, with the pairing of the timings
// that end on a feed row (perfFeedPair: M3, M5) and the hub clock (M4). The
// passive observers that need no component (M6b inp, M7 scroll_jank) start
// here, with the collector.

import { MOBILE_STACK_QUERY } from './mobile-stack.mjs'
import { afterPaint, perfAttach, perfMark, perfMarkReset } from './perf-mark.mjs'

export { perfMark }

/** The hub's sets (store/perf_samples.go, rdb 0106 CHECKs). */
export const PERF_METRICS = Object.freeze(['load_rail', 'load_messages', 'send_ack', 'deliver_visible', 'switch_view', 'type_next_paint', 'inp', 'scroll_jank', 'reconnect_live'])
export const PERF_VIEWS = Object.freeze(['topic', 'channel', 'dm', 'flow', 'search'])
export const PERF_CACHES = Object.freeze(['cold', 'warm'])
export const PERF_OUTCOMES = Object.freeze(['ok', 'fail', 'timeout'])
export const PERF_NETS = Object.freeze(['slow-2g', '2g', '3g', '4g'])
export const PERF_HIDDEN_S = Object.freeze(['30-300', '300-3600', '3600+'])

/** Limits (spec 4 transport and sampling, 4.0 rules). */
export const PERF_BUFFER_MAX = 500
export const PERF_BATCH_MAX = 50
export const PERF_FLUSH_MS = 30_000
export const PERF_HOUR_CAP = 300
export const PERF_SEND_TIMEOUT_MS = 5_000
export const PERF_FAIL_STOP = 3
export const PERF_VALUE_MAX_MS = 600_000
/** M4 (spec 3.1): a clock offset less certain than this drops the sample. */
export const PERF_CLOCK_ERR_MAX_MS = 250
/** M7: a scroll burst ends after this long without a scroll event. */
export const PERF_SCROLL_IDLE_MS = 150

const HOUR_MS = 3_600_000
/** M3: a send start older than this never pairs with a row (a refused send). */
const SEND_PAIR_MS = 10_000
/** M5: a navigation start older than this is not the start of a view switch. */
const NAV_PAIR_MS = 10_000
const perfNow = () => globalThis.performance.now()
const BUILD_RE = /^[0-9A-Za-z.+-]{0,40}$/
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

/** The tab's collector (perf-mark.mjs's sink); null = RUM off or not loaded yet. */
let active = null
/** Stops the passive observers startPerfRum installed. */
let unobserve = null

/** A random lowercase uuid, or '' when the browser has no crypto. */
export function perfSessionId(c = globalThis.crypto) {
  try {
    if (c && typeof c.randomUUID === 'function') return String(c.randomUUID()).toLowerCase()
    if (c && typeof c.getRandomValues === 'function') {
      const b = c.getRandomValues(new Uint8Array(16))
      b[6] = (b[6] & 0x0f) | 0x40
      b[8] = (b[8] & 0x3f) | 0x80
      const h = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')
      return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
    }
  } catch { /* no crypto: no session */ }
  return ''
}

/** 'phone' at the phone layout's breakpoint (useMobileStack), else 'desktop'. */
export function perfDevice(w = globalThis) {
  try {
    return w.matchMedia && w.matchMedia(MOBILE_STACK_QUERY).matches ? 'phone' : 'desktop'
  } catch {
    return 'desktop'
  }
}

/** navigator.connection.effectiveType where the browser has it, else ''. */
export function perfNet(nav = globalThis.navigator) {
  try {
    const t = nav && nav.connection && nav.connection.effectiveType
    return PERF_NETS.includes(t) ? t : ''
  } catch {
    return ''
  }
}

const ms = (v) => {
  const n = Math.round(Number(v))
  return Number.isFinite(n) && n >= 0 && n <= PERF_VALUE_MAX_MS ? n : -1
}
const optIn = (v, set) => v === undefined || v === null || v === '' || set.includes(v)

/**
 * The wire sample, or null when any field is out of its set. Only the names
 * below can leave the page; anything else on `fields` is never read.
 */
export function perfSample(metric, valueMs, fields, ctx) {
  const f = fields && typeof fields === 'object' ? fields : {}
  const value = ms(valueMs)
  if (!PERF_METRICS.includes(metric) || value < 0) return null
  const outcome = f.outcome === undefined ? 'ok' : f.outcome
  if (!PERF_OUTCOMES.includes(outcome)) return null
  if (!optIn(f.view, PERF_VIEWS) || !optIn(f.cache, PERF_CACHES) || !optIn(f.hiddenS, PERF_HIDDEN_S)) return null
  const s = { session_id: ctx.sessionId, metric, value_ms: value, device: ctx.device === 'phone' ? 'phone' : 'desktop', outcome, build: ctx.build }
  if (f.view) s.view = f.view
  if (f.cache) s.cache = f.cache
  if (f.hiddenS) s.hidden_s = f.hiddenS
  if (ctx.net) s.net = ctx.net
  if (f.ratio !== undefined && f.ratio !== null) {
    const r = Number(f.ratio)
    if (!Number.isFinite(r) || r < 0 || r > 1) return null
    s.ratio = r
  }
  if (f.clockErrMs !== undefined && f.clockErrMs !== null) {
    const e = ms(f.clockErrMs)
    if (e < 0) return null
    s.clock_err_ms = e
  }
  return s
}

/** POST one body with fetch, keepalive, text/plain (CORS-safelisted). */
export function perfFetchSender(url, { credentials = 'include', fetchFn = globalThis.fetch } = {}) {
  return (body, signal) => fetchFn(url, { method: 'POST', body, credentials, keepalive: true, cache: 'no-store', headers: { 'content-type': 'text/plain' }, signal })
}

/** The final beacon; false when the browser has none or refuses it. */
export function perfBeaconSender(url, nav = globalThis.navigator) {
  return (body) => {
    try {
      return !!(nav && typeof nav.sendBeacon === 'function' && nav.sendBeacon(url, body))
    } catch {
      return false
    }
  }
}

const idleDefault = (fn) => {
  if (typeof globalThis.requestIdleCallback === 'function') globalThis.requestIdleCallback(fn, { timeout: 2000 })
  else setTimeout(fn, 0)
}

/** The collector's options with every default filled in. */
function perfOptions(opts) {
  const build = String(opts.build || '')
  return {
    send: opts.send,
    beacon: opts.beacon || (() => false),
    sessionId: UUID_RE.test(String(opts.sessionId || '')) ? String(opts.sessionId) : perfSessionId(),
    device: opts.device || perfDevice,
    net: opts.net || perfNet,
    build: BUILD_RE.test(build) ? build : '',
    ready: opts.ready || (() => true),
    now: opts.now || (() => Date.now()),
    wallNow: opts.wallNow || (() => Date.now()),
    setTimer: opts.setTimer || ((fn, t) => setTimeout(fn, t)),
    clearTimer: opts.clearTimer || ((h) => clearTimeout(h)),
    idle: opts.idle || idleDefault,
  }
}

/**
 * One POST raced against PERF_SEND_TIMEOUT_MS (then aborted). Resolves the
 * response when it is 2xx, else null (rejected, thrown, timed out, non-2xx).
 * Never rejects.
 */
function perfSendOnce(o, payload) {
  const ctl = typeof AbortController === 'function' ? new AbortController() : null
  let timer = null
  const timeout = new Promise((resolve) => {
    timer = o.setTimer(() => { try { if (ctl) ctl.abort() } catch { /* ignore */ } resolve(null) }, PERF_SEND_TIMEOUT_MS)
  })
  let sent
  try { sent = Promise.resolve(o.send(payload, ctl ? ctl.signal : undefined)) } catch (e) { sent = Promise.reject(e) }
  return Promise.race([sent, timeout])
    .then((res) => (res && res.ok ? res : null), () => null)
    .finally(() => o.clearTimer(timer))
}

/**
 * M4's clock offset from a 202 {"hub_ms"} (spec 3.1): offset = hub minus the
 * round trip's midpoint, error = half the round trip. Null without hub_ms.
 */
function perfReadClock(res, t0, t1) {
  if (!res || typeof res.json !== 'function' || res.status !== 202) return Promise.resolve(null)
  return Promise.resolve().then(() => res.json()).then((d) => {
    const hub = Number(d && d.hub_ms)
    if (!Number.isFinite(hub)) return null
    return { offsetMs: Math.round(hub - (t0 + t1) / 2), errMs: Math.max(0, Math.round((t1 - t0) / 2)) }
  }).catch(() => null)
}

/** One request body: the samples and how many this tab dropped since the last. */
const perfBody = (rows, dropped) => JSON.stringify({ samples: rows, dropped })

/** pagehide / hidden: what is buffered goes in beacons, one batch each, until one is refused. */
function perfBeaconRest(o, buf, st, stats) {
  try {
    if (st.stopped || !o.ready()) return
    while (buf.length || st.dropped) {
      const rows = buf.slice(0, PERF_BATCH_MAX)
      if (!o.beacon(perfBody(rows, st.dropped))) return
      buf.splice(0, rows.length)
      st.dropped = 0
      stats.beacons++
    }
  } catch { /* fire and forget */ }
}

/**
 * M4 deliver_visible (spec 3.1): hub accept -> painted here, on the hub's
 * clock via the lowest-RTT offset. No offset yet, or one less certain than
 * PERF_CLOCK_ERR_MAX_MS, drops the sample and counts it.
 */
function perfDeliver(clock, stats, mark, hubMs, wallMs) {
  try {
    if (!clock || clock.errMs > PERF_CLOCK_ERR_MAX_MS) { stats.clockDropped++; return false }
    return mark('deliver_visible', Math.max(0, Number(wallMs) + clock.offsetMs - Number(hubMs)), { clockErrMs: clock.errMs })
  } catch {
    return false
  }
}

/**
 * The collector: ring buffer + hourly cap + batcher + sender.
 * @param {{
 *   send: (body: string, signal?: AbortSignal) => Promise<any>,
 *   beacon?: (body: string) => boolean,
 *   sessionId?: string, device?: () => string, net?: () => string, build?: string,
 *   ready?: () => boolean,
 *   now?: () => number, wallNow?: () => number,
 *   setTimer?: (fn: () => void, ms: number) => any, clearTimer?: (h: any) => void,
 *   idle?: (fn: () => void) => void,
 * }} opts
 */
export function createPerfCollector(opts) {
  const o = perfOptions(opts)
  const buf = []
  const st = { dropped: 0, failures: 0, stopped: !o.sessionId, inFlight: false, flushQueued: false, winStart: o.now(), winCount: 0, clock: null, tick: null }
  const stats = { kept: 0, capped: 0, invalid: 0, sent: 0, failed: 0, beacons: 0, clockDropped: 0 }

  function mark(metric, valueMs, fields) {
    try {
      if (st.stopped) return false
      const t = o.now()
      if (t - st.winStart >= HOUR_MS) { st.winStart = t; st.winCount = 0 }
      if (st.winCount >= PERF_HOUR_CAP) { stats.capped++; return false }
      const s = perfSample(metric, valueMs, fields, { sessionId: o.sessionId, device: o.device(), net: o.net(), build: o.build })
      if (!s) { stats.invalid++; return false }
      st.winCount++
      buf.push(s)
      if (buf.length > PERF_BUFFER_MAX) { buf.shift(); st.dropped++ }
      stats.kept++
      if (buf.length >= PERF_BATCH_MAX && !st.flushQueued) { st.flushQueued = true; o.idle(() => { st.flushQueued = false; flush() }) }
      return true
    } catch {
      return false
    }
  }

  /** Send one batch; never throws, never retries. The promise is for tests. */
  function flush() {
    try {
      if (st.stopped || st.inFlight || !o.ready() || (!buf.length && !st.dropped)) return Promise.resolve(false)
      const rows = buf.splice(0, PERF_BATCH_MAX)
      const lost = rows.length + st.dropped
      const payload = perfBody(rows, st.dropped)
      st.dropped = 0
      st.inFlight = true
      const t0 = o.wallNow()
      return perfSendOnce(o, payload).then((res) => {
        st.inFlight = false
        if (!res) return failed(lost)
        st.failures = 0
        stats.sent += rows.length
        perfReadClock(res, t0, o.wallNow()).then((c) => { if (c && (!st.clock || c.errMs < st.clock.errMs)) st.clock = c })
        return true
      })
    } catch {
      return Promise.resolve(false)
    }
  }

  /** A dropped batch: counted, never resent; PERF_FAIL_STOP in a row stop the tab. */
  function failed(n) {
    st.dropped += n
    stats.failed++
    if (++st.failures >= PERF_FAIL_STOP) stop()
    return false
  }

  function loop() {
    st.tick = o.setTimer(() => { if (!st.stopped) { flush(); loop() } }, PERF_FLUSH_MS)
  }

  function stop() {
    st.stopped = true
    buf.length = 0
    if (st.tick !== null) o.clearTimer(st.tick)
    st.tick = null
  }

  if (!st.stopped) loop()
  return {
    mark,
    deliver: (hubMs, wallMs) => perfDeliver(st.clock, stats, mark, hubMs, wallMs),
    flush,
    stop,
    /** pagehide / hidden: the rest goes in beacons. */
    final: () => perfBeaconRest(o, buf, st, stats),
    /** M4's offset to the hub clock from the lowest-RTT exchange, or null. */
    clock: () => st.clock,
    state: () => ({ buffered: buf.length, dropped: st.dropped, failures: st.failures, stopped: st.stopped, sessionId: o.sessionId, ...stats }),
  }
}

/**
 * Start the tab's collector and wire its page events. One per tab; a second
 * call answers the first. Never throws: null when it does not start.
 * @param {{ url: string, credentials?: 'include'|'omit', build?: string, sampleRate?: number|string, ready?: () => boolean, random?: () => number, win?: any }} opts
 */
export function startPerfRum(opts) {
  try {
    if (active) return active
    const url = String((opts && opts.url) || '')
    if (!/^https?:\/\//.test(url)) return null
    const raw = opts.sampleRate
    const rate = raw === undefined || raw === null || raw === '' ? 1 : Number(raw)
    if (!(rate > 0) || (opts.random || Math.random)() >= rate) return null
    const win = opts.win || globalThis
    const c = createPerfCollector({
      send: perfFetchSender(url, { credentials: opts.credentials || 'include' }),
      beacon: perfBeaconSender(url, win.navigator),
      build: opts.build,
      ready: opts.ready,
    })
    if (c.state().stopped) return null
    win.addEventListener('pagehide', () => c.final())
    const doc = win.document
    if (doc) doc.addEventListener('visibilitychange', () => { if (doc.visibilityState === 'hidden') c.final() })
    active = c
    perfAttach({ mark: c.mark, deliver: c.deliver, feed: perfFeedPair })
    unobserve = perfObserve(win, c.mark)
    return c
  } catch {
    return null
  }
}

/**
 * M6b inp: the Event Timing entries of interactions (Chromium, Firefox; Safari
 * has none and keeps M6 alone), one interaction in ten, the first included.
 */
function observeInp(win, mark) {
  const PO = win.PerformanceObserver
  if (typeof PO !== 'function' || !(PO.supportedEntryTypes || []).includes('event')) return () => {}
  let n = 0
  let last = 0
  const po = new PO((list) => {
    for (const e of list.getEntries()) {
      if (!e.interactionId || e.interactionId === last) continue
      last = e.interactionId
      if (n++ % 10 === 0) mark('inp', e.duration)
    }
  })
  po.observe({ type: 'event', durationThreshold: 16, buffered: true })
  return () => po.disconnect()
}

/**
 * M7 scroll_jank: a scroll burst in a feed (.feed-body) from its first scroll
 * event until PERF_SCROLL_IDLE_MS without one. The value is the longest frame
 * gap; the ratio is frames over 50 ms / frames. Frames are counted only
 * during a burst; the listener is passive.
 */
function observeScroll(win, mark) {
  const doc = win.document
  const raf = win.requestAnimationFrame
  if (!doc || typeof raf !== 'function') return () => {}
  const clock = () => win.performance.now()
  let b = null
  const frame = () => {
    if (!b) return
    const t = clock()
    const gap = t - b.last
    b.frames++
    if (gap > b.max) b.max = gap
    if (gap > 50) b.over++
    b.last = t
    if (t - b.scrolled < PERF_SCROLL_IDLE_MS) { raf(frame); return }
    const done = b
    b = null
    if (done.frames >= 2) mark('scroll_jank', done.max, { ratio: done.over / done.frames })
  }
  const onScroll = (ev) => {
    const el = ev.target
    if (!el || typeof el.closest !== 'function' || !el.closest('.feed-body')) return
    const t = clock()
    if (b) { b.scrolled = t; return }
    b = { last: t, scrolled: t, frames: 0, max: 0, over: 0 }
    raf(frame)
  }
  doc.addEventListener('scroll', onScroll, { capture: true, passive: true })
  return () => doc.removeEventListener('scroll', onScroll, { capture: true })
}

/** The passive observers (M6b, M7); never throws. Returns their stop. */
export function perfObserve(win, mark) {
  const stops = []
  for (const watch of [observeInp, observeScroll]) {
    try { stops.push(watch(win, mark)) } catch { /* that metric stays off */ }
  }
  return () => { for (const s of stops) try { s() } catch { /* ignore */ } }
}

/** M5's `view`: the kind of the page only, never an id (spec 4.2). */
export function perfViewKind(path, thread) {
  if (thread) return 'topic'
  const p = String(path || '')
  if (p.startsWith('/dm/')) return 'dm'
  if (p.startsWith('/channel/') || p === '/lobby') return 'channel'
  if (p.startsWith('/t/')) return 'topic'
  if (p.startsWith('/search')) return 'search'
  return undefined
}

/** M3: the oldest send start still young enough to be this row's, or -1. */
function takeSend(st) {
  const t = perfNow()
  while (st.sends.length) {
    const t0 = st.sends.shift()
    if (t - t0 <= SEND_PAIR_MS) return t0
  }
  return -1
}

function sendDone(st, id, ok) {
  const t0 = st.bound.get(id)
  if (t0 === undefined) return
  st.bound.delete(id)
  if (ok) afterPaint(() => perfMark('send_ack', perfNow() - t0))
  else perfMark('send_ack', perfNow() - t0, { outcome: 'fail' })
}

/**
 * A new view in this feed: M5 starts at the navigation, or now when the feed
 * changed view without one (a topic opened in the side pane). A feed born of
 * a navigation (another page) is a switch too; one born with the page load
 * is not. The navigation is NOT taken here: one navigation can change several
 * feeds (the side pane empties as the page goes), and only the first of them
 * to show rows times it.
 */
function feedSwitched(st, f, rows) {
  const nav = st.navAt >= 0 && perfNow() - st.navAt <= NAV_PAIR_MS ? st.navAt : -1
  f.fromNav = nav >= 0
  f.t0 = nav >= 0 ? nav : (f.born ? -1 : perfNow())
  f.pending = new Set()
  f.seen = new Set(rows.map((m) => String(m && m.msg_id)))
  if (f.t0 >= 0) st.landed = true
}

/** M3: pair own rows with the composer's send starts, oldest first. */
function feedSends(st, f, rows, own) {
  const byId = new Map()
  for (const m of rows) {
    const id = String(m && m.msg_id)
    byId.set(id, m)
    if (m && m.pending) {
      f.pending.add(id)
      if (!st.bound.has(id)) {
        const t0 = takeSend(st)
        if (t0 >= 0) st.bound.set(id, t0)
      }
    } else if (!f.seen.has(id) && st.sends.length && typeof own === 'function' && own(m)) {
      /* a send that never showed a pending row (the mock, an echo before the paint) */
      const t0 = takeSend(st)
      if (t0 >= 0) {
        st.bound.set(id, t0)
        sendDone(st, id, true)
      }
    }
  }
  for (const id of f.pending) {
    const m = byId.get(id)
    if (m && m.pending) continue
    f.pending.delete(id)
    /* gone from the feed while pending = the send failed (the store dropped the row) */
    sendDone(st, id, Boolean(m))
  }
  f.seen = new Set(byId.keys())
  if (st.bound.size > 16) st.bound.delete(st.bound.keys().next().value)
}

/**
 * The sink's half of perf-mark.mjs perfFeed: pairs the timings that end on a
 * painted feed row.
 *   M3 send_ack     an own pending row loses `pending` (or arrives confirmed); a
 *                   pending row that leaves the feed is outcome=fail
 *   M5 switch_view  the feed's view changed and its first rows (or empty state) show
 * `st` is perf-mark's shared memory, `f` the feed's own.
 */
export function perfFeedPair(st, f, rows, fresh, shown, o) {
  try {
    if (fresh) feedSwitched(st, f, rows)
    else if (!f.seen) {
      /* the first call since the collector loaded: a baseline, nothing to pair */
      f.t0 = -1
      f.pending = new Set()
      f.seen = new Set(rows.map((m) => String(m && m.msg_id)))
      return
    }
    if (shown && f.t0 >= 0) {
      const t0 = f.t0
      const view = perfViewKind(o.path, o.thread === true)
      const mine = !f.fromNav || st.navAt === t0
      if (f.fromNav && mine) st.navAt = -1
      f.t0 = -1
      if (mine) afterPaint(() => perfMark('switch_view', perfNow() - t0, view ? { view } : undefined))
    }
    if (!fresh) feedSends(st, f, rows, o.own)
  } catch { /* fire and forget */ }
}

/** Tests only: forget the tab's collector. */
export function perfRumReset() {
  if (active) active.stop()
  if (unobserve) unobserve()
  active = null
  unobserve = null
  perfMarkReset()
}
