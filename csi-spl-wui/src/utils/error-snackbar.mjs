// csi-spl-wui/src/utils/error-snackbar.mjs
//
// The error snackbar's state (005 FR-WUI-ERR-SNACK).
//
// Owner, 2026-09-25: "all of the errors to occur via a cool sliding snackbar
// from the top".
//
// Every failure already lands in ONE place, composables/errorJournal.mjs. This
// module is only the queue the snackbar renders: which records are on screen,
// how many times each repeated, when each one goes away. It opens no second
// error channel — bindSnackbarToJournal feeds it from the journal.
//
// Pure ES module: no Vue, no DOM, no timers of its own (the component drives
// tick()), so the unit suite executes it under bare `node`.
//
// API for components/common/ErrorSnackbar.vue:
//
//   const q = createSnackbarQueue()           // one per mounted snackbar
//   const unbind = bindSnackbarToJournal(q, { getErrors, subscribeErrors })
//   q.subscribe((items) => { ... })           // items: newest FIRST
//   const stop = tickWhileShown(q)            // q.tick() only while rows show
//   q.dismiss(id)                             // the close button
//   q.hold(id, true|false)                    // hover / focus pauses the clock
//
//   item = { id, errorId, text, source, status, count, at, expiresAt, held }
//     text     one line, already redacted by the journal (never HTML)
//     count    how many identical errors this row stands for (>= 1)

/** At most this many rows on screen; the oldest is dropped for a new one. */
export const SNACKBAR_MAX = 3
/** How long a row stays up after its last occurrence. */
export const SNACKBAR_TTL_MS = 8000
/** An identical error within this window bumps the count instead of a new row. */
export const SNACKBAR_COALESCE_MS = 5000
/** How often the component should call tick(). */
export const SNACKBAR_TICK_MS = 500
/** A journal record older than this at bind time is history, not news. */
export const SNACKBAR_REPLAY_MS = 15000
/** Longest line on screen; the event log keeps the whole (capped) message. */
export const SNACKBAR_TEXT_CHARS = 200

/**
 * The one line a snackbar row shows for a journal record. Falls back from the
 * message to the error code, the error name and the HTTP status, so a row is
 * never blank.
 *
 * @param {any} rec
 * @returns {string}
 */
export function snackbarText(rec) {
  if (!rec || typeof rec !== 'object') return ''
  const pick = [rec.message, rec.code, rec.name]
    .map((v) => (typeof v === 'string' ? v.trim() : ''))
    .find(Boolean)
  let s = pick || (Number(rec.status) > 0 ? `HTTP ${Number(rec.status)}` : 'Error')
  if (s.length > SNACKBAR_TEXT_CHARS) s = s.slice(0, SNACKBAR_TEXT_CHARS - 1) + '…'
  return s
}

/** What makes two records "the same error" for coalescing. */
function sameKey(rec, text) {
  return [String(rec.source || ''), String(rec.method || ''), String(rec.path || ''),
    String(Number(rec.status) || 0), text].join('\u0001')
}

/** createSnackbarQueue's options with every default filled in. */
function snackbarOptions(opts) {
  return {
    now: typeof opts.now === 'function' ? opts.now : () => Date.now(),
    max: Number.isFinite(opts.max) && opts.max > 0 ? opts.max : SNACKBAR_MAX,
    ttl: Number.isFinite(opts.ttlMs) && opts.ttlMs > 0 ? opts.ttlMs : SNACKBAR_TTL_MS,
    coalesce: Number.isFinite(opts.coalesceMs) && opts.coalesceMs >= 0 ? opts.coalesceMs : SNACKBAR_COALESCE_MS,
  }
}

/** A repeat of the error `hit` shows at time t: count it and restart its clock. */
function bumpRow(hit, rec, t, ttl) {
  hit.count += 1
  hit.lastAt = t
  hit.expiresAt = t + ttl
  hit.errorId = String(rec.errorId || hit.errorId)
  hit.at = String(rec.at || hit.at)
}

/** A fresh row for journal record `rec`, first shown at time t. */
function newRow({ id, key, text, rec, t, ttl }) {
  return {
    id,
    key,
    errorId: String(rec.errorId || ''),
    text,
    source: String(rec.source || ''),
    status: Number(rec.status) || 0,
    count: 1,
    at: String(rec.at || ''),
    lastAt: t,
    expiresAt: t + ttl,
    held: false,
  }
}

/** The rows as subscribers see them: without the coalescing key and clock. */
function publicRows(rows) {
  return rows.map(({ key, lastAt, ...pub }) => ({ ...pub }))
}

/** Hand every subscriber the same snapshot. */
function notifyAll(listeners, snap) {
  for (const fn of listeners) {
    try { fn(snap) } catch { /* a bad subscriber must not break the queue */ }
  }
}

/**
 * @param {{ now?: () => number, max?: number, ttlMs?: number, coalesceMs?: number }} [opts]
 */
export function createSnackbarQueue(opts = {}) {
  const { now, max, ttl, coalesce } = snackbarOptions(opts)

  /** @type {any[]} newest first */
  let rows = []
  let nextId = 0
  const listeners = new Set()

  const view = () => publicRows(rows)
  const emit = () => notifyAll(listeners, view())

  /**
   * Show one journal record. Returns the row's id, or '' when the record is
   * not showable.
   * @param {any} rec
   */
  function push(rec) {
    try {
      if (!rec || typeof rec !== 'object') return ''
      const text = snackbarText(rec)
      const key = sameKey(rec, text)
      const t = now()
      const hit = rows.find((r) => r.key === key && t - r.lastAt <= coalesce)
      if (hit) {
        bumpRow(hit, rec, t, ttl)
        rows = [hit, ...rows.filter((r) => r !== hit)]
      } else {
        nextId += 1
        rows = [newRow({ id: `snack-${nextId}`, key, text, rec, t, ttl }), ...rows].slice(0, max)
      }
      emit()
      // The row this record landed on is the newest, so it is first.
      return rows[0].id
    } catch {
      return ''
    }
  }

  /** Remove a row now (close button). */
  function dismiss(id) {
    const before = rows.length
    rows = rows.filter((r) => r.id !== id)
    if (rows.length !== before) emit()
  }

  /** Pause (true) or restart (false) a row's clock — hover and focus. */
  function hold(id, on) {
    const r = rows.find((x) => x.id === id)
    if (!r || r.held === !!on) return
    r.held = !!on
    // Letting go gives the reader the full time again, not the stub that was
    // left when they started reading.
    if (!on) r.expiresAt = now() + ttl
    emit()
  }

  /** Drop expired rows. Returns true when something changed. */
  function tick() {
    const t = now()
    const keep = rows.filter((r) => r.held || r.expiresAt > t)
    if (keep.length === rows.length) return false
    rows = keep
    emit()
    return true
  }

  function clear() {
    if (!rows.length) return
    rows = []
    emit()
  }

  function subscribe(fn) {
    listeners.add(fn)
    return () => { listeners.delete(fn) }
  }

  return { push, dismiss, hold, tick, clear, subscribe, items: view }
}

/**
 * Run `queue.tick()` every SNACKBAR_TICK_MS only while a row is on screen.
 * An empty queue's tick() changes nothing, yet the old always-on interval
 * woke the tab twice a second for its whole life (CLE-35075). The first row
 * starts the clock, the last row leaving stops it; rows expire exactly as
 * before because every row is pushed through the queue, and a push emits.
 *
 * @param {ReturnType<typeof createSnackbarQueue>} queue
 * @param {{ every?: (fn: () => void, ms: number) => unknown, cancel?: (id: unknown) => void }} [timers]
 * @returns {() => void} stop
 */
export function tickWhileShown(queue, timers = {}) {
  const every = timers.every || ((fn, ms) => setInterval(fn, ms))
  const cancel = timers.cancel || ((id) => clearInterval(/** @type {any} */ (id)))
  let id = null
  function sync(items) {
    if (items.length && id == null) id = every(() => { queue.tick() }, SNACKBAR_TICK_MS)
    else if (!items.length && id != null) {
      cancel(id)
      id = null
    }
  }
  const unsub = queue.subscribe(sync)
  sync(queue.items())
  return () => {
    unsub()
    if (id != null) cancel(id)
    id = null
  }
}

/**
 * Feed a queue from the journal. The journal emits its whole buffer on every
 * change, so only records with a `seq` above the last one seen are new. On
 * bind, records younger than SNACKBAR_REPLAY_MS are shown too — an error
 * raised while the page was still booting is still news.
 *
 * @param {ReturnType<typeof createSnackbarQueue>} queue
 * @param {{ getErrors: () => any[], subscribeErrors: (fn: (r: any[]) => void) => () => void, now?: () => number }} journal
 * @returns {() => void} unbind
 */
export function bindSnackbarToJournal(queue, journal) {
  const now = typeof journal.now === 'function' ? journal.now : () => Date.now()
  let lastSeq = 0
  const seqOf = (r) => (r && Number.isFinite(Number(r.seq)) ? Number(r.seq) : 0)

  function take(records, replay) {
    for (const r of Array.isArray(records) ? records : []) {
      const s = seqOf(r)
      if (s <= lastSeq) continue
      lastSeq = s
      if (replay) {
        const at = Date.parse(String(r.at || ''))
        if (!Number.isFinite(at) || now() - at > SNACKBAR_REPLAY_MS) continue
      }
      queue.push(r)
    }
  }

  let initial = []
  try { initial = journal.getErrors() } catch { initial = [] }
  take(initial, true)
  // clearErrors() empties the buffer; the journal's seq never goes back, so
  // the next record is still above lastSeq.
  return journal.subscribeErrors((records) => take(records, false))
}
