// csi-spl-wui/src/utils/event-log.mjs
//
// The personal event log (005 FR-WUI-EVLOG, contracts/events-v1.md).
//
// Owner, 2026-09-25: "all of the errors should get saved into a personal per
// user event-log entry in the db, which should be accessible from event log,
// button after the flow icon on the left most pane".
//
// Two halves, both pure (no Vue, no DOM), executed by the unit suite:
//
//   createEventsClient  events-v1 over fetch: list / add / clear. Every call
//                       resolves (never throws) to { ok, status, data, error,
//                       retryAfter }, the human-keys client's shape.
//   createEventShipper  batches journal records to POST /api/v1/auth/events
//                       while the session is signed in.
//
// SECURITY — only the fields the journal already redacted at capture leave the
// page (EVENT_FIELDS). No body, no header, no query string, no stack.
//
// NO LOOP — the shipper talks to fetch directly, never through spool-client
// (whose transport failures are journaled) and never calls noteError. A POST
// that fails is dropped or retried quietly; it is never itself an error event.

import { AUTH_PREFIX, authOrigin } from './auth-client.mjs'

/** The record fields events-v1 stores, journal name -> wire name. */
export const EVENT_FIELDS = Object.freeze({
  errorId: 'error_id',
  at: 'at',
  source: 'source',
  method: 'method',
  origin: 'origin',
  path: 'path',
  status: 'status',
  code: 'code',
  message: 'message',
  name: 'name',
  route: 'route',
})

/** Caps the hub enforces too (events-v1 §2). Longer = cut here, not refused. */
export const EVENT_CAPS = Object.freeze({
  error_id: 40, at: 40, source: 80, method: 12, origin: 120, path: 200,
  code: 120, message: 800, name: 80, route: 200,
})

/** One POST carries at most this many events (hub: 400 above it). */
export const EVENT_BATCH_MAX = 20
/** Unsent events kept while a flush is pending; the oldest go first. */
export const EVENT_QUEUE_MAX = 100
/** Wait this long after an error so a burst goes in one POST. */
export const EVENT_FLUSH_DELAY_MS = 1500
/** Transport/5xx retries of one batch before it is dropped. */
export const EVENT_RETRY_MAX = 3

const cut = (v, n) => {
  const s = typeof v === 'string' ? v : v == null ? '' : String(v)
  return s.length > n ? s.slice(0, n - 1) + '…' : s
}

/**
 * The wire form of one journal record, or null when it is not a record.
 * @param {any} rec
 */
export function toEventPayload(rec) {
  if (!rec || typeof rec !== 'object') return null
  const out = {}
  for (const [from, to] of Object.entries(EVENT_FIELDS)) {
    if (to === 'status') {
      const n = Math.trunc(Number(rec[from]))
      out.status = Number.isFinite(n) && n >= 0 && n <= 999 ? n : 0
    } else {
      out[to] = cut(rec[from], EVENT_CAPS[to])
    }
  }
  return out
}

/**
 * events-v1 client.
 * @param {{ fetchFn?: typeof fetch, base?: string }} [opts]
 */
export function createEventsClient({ fetchFn = globalThis.fetch, base = '' } = {}) {
  const root = `${authOrigin(base)}${AUTH_PREFIX}/events`
  async function call(path, opts = {}) {
    let res
    try {
      res = await fetchFn(root + path, {
        credentials: 'include',
        cache: 'no-store',
        ...opts,
        headers: { accept: 'application/json', ...(opts.body ? { 'content-type': 'application/json' } : {}) },
      })
    } catch {
      return { ok: false, status: 0, data: null, error: 'network', retryAfter: 0 }
    }
    let data = null
    try { data = await res.json() } catch { data = null }
    if (res.ok) return { ok: true, status: res.status, data, error: '', retryAfter: 0 }
    const ra = res.headers && typeof res.headers.get === 'function' ? Number(res.headers.get('retry-after')) : 0
    return {
      ok: false,
      status: res.status,
      data,
      error: String((data && data.error) || (res.status === 429 ? 'rate_limited' : 'unavailable')),
      retryAfter: Number.isFinite(ra) && ra > 0 ? ra : 0,
    }
  }
  return {
    /** Newest first. `before` = the smallest id already shown (paging). */
    list: ({ limit = 50, before = 0 } = {}) => {
      const q = new URLSearchParams({ limit: String(limit) })
      if (Number(before) > 0) q.set('before', String(Math.trunc(Number(before))))
      return call(`?${q}`)
    },
    /** @param {object[]} events wire-form events (toEventPayload) */
    add: (events) => call('', { method: 'POST', body: JSON.stringify({ events: Array.isArray(events) ? events : [] }) }),
    clear: () => call('/clear', { method: 'POST', body: '{}' }),
  }
}

/**
 * Batch journal records to the hub.
 *
 * `session()` answers 'in' | 'out' | 'unknown' | 'loading'. While it is not
 * yet known, records wait; signed out, they are dropped (an error with no
 * signed-in human belongs to nobody's log). Signed in, a flush runs
 * EVENT_FLUSH_DELAY_MS after the first queued record.
 *
 * @param {{
 *   client: ReturnType<typeof createEventsClient>,
 *   session: () => string,
 *   setTimer?: (fn: () => void, ms: number) => any,
 *   clearTimer?: (h: any) => void,
 *   delayMs?: number,
 * }} opts
 */
export function createEventShipper(opts) {
  const client = opts.client
  const session = opts.session
  const setTimer = opts.setTimer || ((fn, ms) => setTimeout(fn, ms))
  const clearTimer = opts.clearTimer || ((h) => clearTimeout(h))
  const delay = Number.isFinite(opts.delayMs) && opts.delayMs >= 0 ? opts.delayMs : EVENT_FLUSH_DELAY_MS

  /** @type {object[]} */
  let queue = []
  let timer = null
  let busy = false
  let failures = 0

  function schedule(ms) {
    if (timer != null) return
    timer = setTimer(() => {
      timer = null
      void flush()
    }, ms)
  }

  /** @param {any} rec a journal record */
  function note(rec) {
    try {
      const st = session()
      if (st === 'out') return
      const ev = toEventPayload(rec)
      if (!ev) return
      queue.push(ev)
      if (queue.length > EVENT_QUEUE_MAX) queue.splice(0, queue.length - EVENT_QUEUE_MAX)
      if (st === 'in') schedule(delay)
    } catch {
      /* the shipper must never become an error of its own */
    }
  }

  /** Send what is queued. Resolves to the number of events the hub took. */
  async function flush() {
    if (busy) return 0
    const st = session()
    if (st === 'out') { queue = []; return 0 }
    if (st !== 'in' || !queue.length) return 0
    busy = true
    let sent = 0
    try {
      while (queue.length) {
        const batch = queue.slice(0, EVENT_BATCH_MAX)
        const res = await client.add(batch)
        if (res.ok) {
          queue.splice(0, batch.length)
          sent += batch.length
          failures = 0
          continue
        }
        if (res.status === 401 || res.status === 403) {
          // No longer signed in as anyone who owns a log: nothing to keep.
          queue = []
          break
        }
        if (res.status === 429 || res.status === 0 || res.status >= 500) {
          failures += 1
          if (failures > EVENT_RETRY_MAX) {
            queue.splice(0, batch.length)
            failures = 0
            continue
          }
          const wait = res.retryAfter > 0 ? res.retryAfter * 1000 : delay * 2 ** failures
          schedule(wait)
          break
        }
        // Any other 4xx: the hub will never take this batch. Drop it.
        queue.splice(0, batch.length)
      }
    } catch {
      /* never throws */
    } finally {
      busy = false
    }
    return sent
  }

  /** The session changed: ship what waited for it, or drop it on sign-out. */
  function sessionChanged() {
    const st = session()
    if (st === 'out') {
      queue = []
      if (timer != null) { clearTimer(timer); timer = null }
    } else if (st === 'in' && queue.length) {
      schedule(0)
    }
  }

  function stop() {
    if (timer != null) { clearTimer(timer); timer = null }
  }

  return { note, flush, sessionChanged, stop, size: () => queue.length }
}

/**
 * Feed a shipper from the journal: every record with a `seq` above the last
 * one seen, including the ones already buffered when the page booted.
 *
 * @param {{ note: (r: any) => void }} shipper
 * @param {{ getErrors: () => any[], subscribeErrors: (fn: (r: any[]) => void) => () => void }} journal
 * @returns {() => void} unbind
 */
export function bindShipperToJournal(shipper, journal) {
  let lastSeq = 0
  function take(records) {
    for (const r of Array.isArray(records) ? records : []) {
      const s = r && Number.isFinite(Number(r.seq)) ? Number(r.seq) : 0
      if (s <= lastSeq) continue
      lastSeq = s
      shipper.note(r)
    }
  }
  try { take(journal.getErrors()) } catch { /* nothing buffered */ }
  return journal.subscribeErrors(take)
}

/** i18n key for an events-v1 error token. */
export function eventsErrorKey(error) {
  return error === 'unauthenticated' ? 'events.signed_out' : 'events.load_failed'
}
