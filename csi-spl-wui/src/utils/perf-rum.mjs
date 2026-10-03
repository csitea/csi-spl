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

import { MOBILE_STACK_QUERY } from './mobile-stack.mjs'

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

const HOUR_MS = 3_600_000
const BUILD_RE = /^[0-9A-Za-z.+-]{0,40}$/
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

/** The collector perfMark feeds; null = RUM off or not loaded yet. */
let active = null

/**
 * Record one timing. Synchronous, never throws, never awaits.
 * @param {string} metric one of PERF_METRICS
 * @param {number} valueMs the measured time in ms
 * @param {{ view?: string, cache?: string, outcome?: string, ratio?: number, clockErrMs?: number, hiddenS?: string }} [fields]
 * @returns {boolean} true when the sample was kept
 */
export function perfMark(metric, valueMs, fields) {
  try {
    return active ? active.mark(metric, valueMs, fields) : false
  } catch {
    return false
  }
}

/** The running collector (tests, the L6 observers), or null. */
export function perfCollector() {
  return active
}

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
  const stats = { kept: 0, capped: 0, invalid: 0, sent: 0, failed: 0, beacons: 0 }

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
    return c
  } catch {
    return null
  }
}

/** Tests only: forget the tab's collector. */
export function perfRumReset() {
  if (active) active.stop()
  active = null
}
