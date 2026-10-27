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
//   createQueueStore    keeps the unsent queue in the tab's sessionStorage, so
//                       an error that could not be sent survives a reload and
//                       ships on the next load (SPL-7, owner topic 4335f075).
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
/** sessionStorage key of the unsent queue (wire-form events, a JSON array). */
export const EVENT_QUEUE_STORE_KEY = 'spl.event-log.queue.v1'

const cut = (v, n) => {
  const s = typeof v === 'string' ? v : v == null ? '' : String(v)
  return s.length > n ? s.slice(0, n - 1) + '…' : s
}

/**
 * The wire form of one journal record, or null when it is not a record.
 * @param {any} rec
 */
export function toEventPayload(rec) {
  return wireForm(rec, (from) => rec[from])
}

/**
 * A stored event back in wire form, or null when it is not one. The store is
 * the page's own, but anything read back is re-cut to EVENT_CAPS so a stale
 * or edited entry can never send more than toEventPayload would.
 * @param {any} ev
 */
function storedEvent(ev) {
  return Array.isArray(ev) ? null : wireForm(ev, (_from, to) => ev[to])
}

/** The capped wire form of `obj`, each field read by `pick(journalName, wireName)`. */
function wireForm(obj, pick) {
  if (!obj || typeof obj !== 'object') return null
  const out = {}
  for (const [from, to] of Object.entries(EVENT_FIELDS)) {
    if (to === 'status') {
      const n = Math.trunc(Number(pick(from, to)))
      out.status = Number.isFinite(n) && n >= 0 && n <= 999 ? n : 0
    } else {
      out[to] = cut(pick(from, to), EVENT_CAPS[to])
    }
  }
  return out
}

/**
 * The unsent queue in a Web Storage area (sessionStorage: this tab only, gone
 * when the tab closes). Every call is silent: no storage, a full quota or a
 * corrupt entry reads as an empty queue and writes as a no-op.
 *
 * @param {Storage | null | undefined} storage
 * @param {string} [key]
 * @returns {{ load: () => object[], save: (queue: object[]) => void }}
 */
export function createQueueStore(storage, key = EVENT_QUEUE_STORE_KEY) {
  return {
    load() {
      try {
        const raw = storage ? storage.getItem(key) : null
        const arr = raw ? JSON.parse(raw) : []
        if (!Array.isArray(arr)) return []
        return arr.map(storedEvent).filter(Boolean).slice(-EVENT_QUEUE_MAX)
      } catch {
        return []
      }
    },
    save(queue) {
      try {
        if (!storage) return
        if (queue.length) storage.setItem(key, JSON.stringify(queue))
        else storage.removeItem(key)
      } catch {
        /* quota or blocked storage: the queue still lives in memory */
      }
    },
  }
}

/** The browser tab's sessionStorage, or null (node, blocked storage). */
function tabStorage() {
  try {
    return typeof window !== 'undefined' && window.sessionStorage ? window.sessionStorage : null
  } catch {
    return null
  }
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
 * What the hub's answer to one batch means (pure), and the failure count after it:
 *   sent  - taken; the batch leaves the queue
 *   clear - 401 / 403: no longer signed in as anyone who owns a log, so
 *           nothing queued is worth keeping
 *   retry - 429 / no answer / 5xx with retries left: wait, then send again
 *   drop  - out of retries, or any other 4xx: the hub will never take it
 *
 * @param {{ ok: boolean, status: number }} res
 * @param {number} failures transient failures in a row so far
 */
function batchVerdict(res, failures) {
  if (res.ok) return { verdict: 'sent', failures: 0 }
  if (res.status === 401 || res.status === 403) return { verdict: 'clear', failures }
  if (res.status === 429 || res.status === 0 || res.status >= 500) {
    if (failures + 1 > EVENT_RETRY_MAX) return { verdict: 'drop', failures: 0 }
    return { verdict: 'retry', failures: failures + 1 }
  }
  return { verdict: 'drop', failures }
}

/** createEventShipper's options with every default filled in. */
function shipperOptions(opts) {
  return {
    client: opts.client,
    session: opts.session,
    setTimer: opts.setTimer || ((fn, ms) => setTimeout(fn, ms)),
    clearTimer: opts.clearTimer || ((h) => clearTimeout(h)),
    delay: Number.isFinite(opts.delayMs) && opts.delayMs >= 0 ? opts.delayMs : EVENT_FLUSH_DELAY_MS,
    store: opts.store === undefined ? createQueueStore(tabStorage()) : opts.store,
  }
}

/**
 * The shipper's queue of wire-form events, oldest first, capped at
 * EVENT_QUEUE_MAX (the oldest go first), mirrored to `store` on every change.
 * @param {{ load: () => object[], save: (queue: object[]) => void } | null} store
 */
function persistedQueue(store) {
  let items = store ? store.load() : []
  const save = () => { if (store) store.save(items) }
  return {
    get length() { return items.length },
    head: (n) => items.slice(0, n),
    push(ev) {
      items.push(ev)
      if (items.length > EVENT_QUEUE_MAX) items.splice(0, items.length - EVENT_QUEUE_MAX)
      save()
    },
    drop(n) { items.splice(0, n); save() },
    clear() { items = []; save() },
  }
}

/**
 * One shipper's state: its options, its queue, the pending timer handle, the
 * re-entry guard of `flush` and the transient failures in a row.
 * @typedef {ReturnType<typeof shipperOptions> & {
 *   queue: ReturnType<typeof persistedQueue>,
 *   timer: any, busy: boolean, failures: number,
 * }} ShipperState
 */

/** Arm the flush timer for `ms` unless one is already pending. @param {ShipperState} s @param {number} ms */
function shipperSchedule(s, ms) {
  if (s.timer != null) return
  s.timer = s.setTimer(() => {
    s.timer = null
    void shipperFlush(s)
  }, ms)
}

/** Queue one journal record, and arm the timer when signed in. @param {ShipperState} s @param {any} rec */
function shipperNote(s, rec) {
  try {
    const st = s.session()
    if (st === 'out') return
    const ev = toEventPayload(rec)
    if (!ev) return
    s.queue.push(ev)
    if (st === 'in') shipperSchedule(s, s.delay)
  } catch {
    /* the shipper must never become an error of its own */
  }
}

/** POST the queue batch by batch until it is empty, cleared or must wait; resolves to the events taken. @param {ShipperState} s */
async function shipBatches(s) {
  let sent = 0
  while (s.queue.length) {
    const batch = s.queue.head(EVENT_BATCH_MAX)
    const res = await s.client.add(batch)
    const next = batchVerdict(res, s.failures)
    s.failures = next.failures
    if (next.verdict === 'clear') { s.queue.clear(); break }
    if (next.verdict === 'retry') {
      shipperSchedule(s, res.retryAfter > 0 ? res.retryAfter * 1000 : s.delay * 2 ** s.failures)
      break
    }
    s.queue.drop(batch.length)
    if (next.verdict === 'sent') sent += batch.length
  }
  return sent
}

/** Send what is queued. Resolves to the number of events the hub took. @param {ShipperState} s */
async function shipperFlush(s) {
  if (s.busy) return 0
  const st = s.session()
  if (st === 'out') { s.queue.clear(); return 0 }
  if (st !== 'in' || !s.queue.length) return 0
  s.busy = true
  let sent = 0
  try {
    sent = await shipBatches(s)
  } catch {
    /* never throws */
  } finally {
    s.busy = false
  }
  return sent
}

/** The session changed: ship what waited for it, or drop it on sign-out. @param {ShipperState} s */
function shipperSessionChanged(s) {
  const st = s.session()
  if (st === 'out') {
    s.queue.clear()
    shipperStop(s)
  } else if (st === 'in' && s.queue.length) {
    shipperSchedule(s, 0)
  }
}

/** Cancel the pending flush timer, if any. @param {ShipperState} s */
function shipperStop(s) {
  if (s.timer != null) { s.clearTimer(s.timer); s.timer = null }
}

/**
 * Batch journal records to the hub.
 *
 * `session()` answers 'in' | 'out' | 'unknown' | 'loading'. While it is not
 * yet known, records wait; signed out, they are dropped (an error with no
 * signed-in human belongs to nobody's log). Signed in, a flush runs
 * EVENT_FLUSH_DELAY_MS after the first queued record.
 *
 * The queue is mirrored to `store` (default: the tab's sessionStorage; null =
 * memory only) on every change and read back at creation, so what a reload
 * cut off ships on the next load. A batch leaves the store only once the hub
 * answered for it: a reload during its POST sends it again (at least once).
 *
 * @param {{
 *   client: ReturnType<typeof createEventsClient>,
 *   session: () => string,
 *   setTimer?: (fn: () => void, ms: number) => any,
 *   clearTimer?: (h: any) => void,
 *   delayMs?: number,
 *   store?: { load: () => object[], save: (queue: object[]) => void } | null,
 * }} opts
 */
export function createEventShipper(opts) {
  const o = shipperOptions(opts)
  /** @type {ShipperState} */
  const s = { ...o, queue: persistedQueue(o.store), timer: null, busy: false, failures: 0 }

  shipperSessionChanged(s) // what the last page left unsent: ship it, drop it, or wait

  return {
    /** @param {any} rec a journal record */
    note: (rec) => shipperNote(s, rec),
    flush: () => shipperFlush(s),
    sessionChanged: () => shipperSessionChanged(s),
    stop: () => shipperStop(s),
    size: () => s.queue.length,
  }
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
