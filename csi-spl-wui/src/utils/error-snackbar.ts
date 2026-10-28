// csi-spl-wui/src/utils/error-snackbar.ts
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
const SNACKBAR_COALESCE_MS = 5000
/** How often the component should call tick(). */
export const SNACKBAR_TICK_MS = 500
/** A journal record older than this at bind time is history, not news. */
const SNACKBAR_REPLAY_MS = 15000
/** Longest line on screen; the event log keeps the whole (capped) message. */
const SNACKBAR_TEXT_CHARS = 200

/** One row as a subscriber sees it. */
export interface SnackbarItem {
  id: string
  errorId: string
  text: string
  source: string
  status: number
  count: number
  at: string
  expiresAt: number
  held: boolean
}

/** A row inside the queue: the public fields plus the coalescing key and clock. */
type SnackbarRow = SnackbarItem & { key: string, lastAt: number }

/** The journal record fields the queue reads. */
type JournalRec = { message?: unknown, code?: unknown, name?: unknown, status?: unknown, source?: unknown, method?: unknown, path?: unknown, errorId?: unknown, at?: unknown, seq?: unknown, inline?: unknown }

/** The queue createSnackbarQueue returns. */
export interface SnackbarQueue {
  push(rec: unknown): string
  dismiss(id: string): void
  hold(id: string, on: boolean): void
  tick(): boolean
  clear(): void
  subscribe(fn: (items: SnackbarItem[]) => void): () => void
  items(): SnackbarItem[]
}

/**
 * The one line a snackbar row shows for a journal record. Falls back from the
 * message to the error code, the error name and the HTTP status, so a row is
 * never blank.
 */
export function snackbarText(raw: unknown): string {
  if (!raw || typeof raw !== 'object') return ''
  const rec = raw as JournalRec
  const pick = [rec.message, rec.code, rec.name]
    .map((v) => (typeof v === 'string' ? v.trim() : ''))
    .find(Boolean)
  let s = pick || (Number(rec.status) > 0 ? `HTTP ${Number(rec.status)}` : 'Error')
  if (s.length > SNACKBAR_TEXT_CHARS) s = s.slice(0, SNACKBAR_TEXT_CHARS - 1) + '…'
  return s
}

/** What makes two records "the same error" for coalescing. */
function sameKey(rec: JournalRec, text: string): string {
  return [String(rec.source || ''), String(rec.method || ''), String(rec.path || ''),
    String(Number(rec.status) || 0), text].join('\u0001')
}

/** createSnackbarQueue's options with every default filled in. */
function snackbarOptions(opts: { now?: () => number, max?: number, ttlMs?: number, coalesceMs?: number }) {
  return {
    now: typeof opts.now === 'function' ? opts.now : () => Date.now(),
    max: Number.isFinite(opts.max) && Number(opts.max) > 0 ? Number(opts.max) : SNACKBAR_MAX,
    ttl: Number.isFinite(opts.ttlMs) && Number(opts.ttlMs) > 0 ? Number(opts.ttlMs) : SNACKBAR_TTL_MS,
    coalesce: Number.isFinite(opts.coalesceMs) && Number(opts.coalesceMs) >= 0 ? Number(opts.coalesceMs) : SNACKBAR_COALESCE_MS,
  }
}

/** A repeat of the error `hit` shows at time t: count it and restart its clock. */
function bumpRow(hit: SnackbarRow, rec: JournalRec, t: number, ttl: number): void {
  hit.count += 1
  hit.lastAt = t
  hit.expiresAt = t + ttl
  hit.errorId = String(rec.errorId || hit.errorId)
  hit.at = String(rec.at || hit.at)
}

/** A fresh row for journal record `rec`, first shown at time t. */
function newRow({ id, key, text, rec, t, ttl }: { id: string, key: string, text: string, rec: JournalRec, t: number, ttl: number }): SnackbarRow {
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
function publicRows(rows: SnackbarRow[]): SnackbarItem[] {
  return rows.map(({ key, lastAt, ...pub }) => ({ ...pub }))
}

/** Hand every subscriber the same snapshot. */
function notifyAll(listeners: Set<(items: SnackbarItem[]) => void>, snap: SnackbarItem[]): void {
  for (const fn of listeners) {
    try { fn(snap) } catch { /* a bad subscriber must not break the queue */ }
  }
}

/** createSnackbarQueue's state: its options, rows newest first, the last id and the subscribers. */
type QueueState = ReturnType<typeof snackbarOptions> & {
  rows: SnackbarRow[]
  nextId: number
  listeners: Set<(items: SnackbarItem[]) => void>
}

/** Hand every subscriber the queue's current rows. */
function queueEmit(st: QueueState): void {
  notifyAll(st.listeners, publicRows(st.rows))
}

/**
 * Show one journal record: bump the row of an identical error inside the
 * coalesce window and move it to the front, else add a new row on top.
 * Returns the row's id, or '' when the record is not showable.
 */
function queuePush(st: QueueState, raw: unknown): string {
  try {
    if (!raw || typeof raw !== 'object') return ''
    const rec = raw as JournalRec
    const text = snackbarText(rec)
    const key = sameKey(rec, text)
    const t = st.now()
    const hit = st.rows.find((r) => r.key === key && t - r.lastAt <= st.coalesce)
    if (hit) {
      bumpRow(hit, rec, t, st.ttl)
      st.rows = [hit, ...st.rows.filter((r) => r !== hit)]
    } else {
      st.nextId += 1
      st.rows = [newRow({ id: `snack-${st.nextId}`, key, text, rec, t, ttl: st.ttl }), ...st.rows].slice(0, st.max)
    }
    queueEmit(st)
    // The row this record landed on is the newest, so it is first.
    return st.rows[0]?.id ?? ''
  } catch {
    return ''
  }
}

/** Pause (true) or restart (false) a row's clock — hover and focus. */
function queueHold(st: QueueState, id: string, on: boolean): void {
  const r = st.rows.find((x) => x.id === id)
  if (!r || r.held === !!on) return
  r.held = !!on
  // Letting go gives the reader the full time again, not the stub that was
  // left when they started reading.
  if (!on) r.expiresAt = st.now() + st.ttl
  queueEmit(st)
}

/** Drop expired rows. Returns true when something changed. */
function queueTick(st: QueueState): boolean {
  const t = st.now()
  const keep = st.rows.filter((r) => r.held || r.expiresAt > t)
  if (keep.length === st.rows.length) return false
  st.rows = keep
  queueEmit(st)
  return true
}

export function createSnackbarQueue(opts: { now?: () => number, max?: number, ttlMs?: number, coalesceMs?: number } = {}): SnackbarQueue {
  const st: QueueState = { ...snackbarOptions(opts), rows: [], nextId: 0, listeners: new Set() }

  /** Remove a row now (close button). */
  function dismiss(id: string): void {
    const before = st.rows.length
    st.rows = st.rows.filter((r) => r.id !== id)
    if (st.rows.length !== before) queueEmit(st)
  }

  function clear(): void {
    if (!st.rows.length) return
    st.rows = []
    queueEmit(st)
  }

  function subscribe(fn: (items: SnackbarItem[]) => void): () => void {
    st.listeners.add(fn)
    return () => { st.listeners.delete(fn) }
  }

  return {
    push: (raw) => queuePush(st, raw),
    dismiss,
    hold: (id, on) => queueHold(st, id, on),
    tick: () => queueTick(st),
    clear,
    subscribe,
    items: () => publicRows(st.rows),
  }
}

/**
 * Run `queue.tick()` every SNACKBAR_TICK_MS only while a row is on screen.
 * An empty queue's tick() changes nothing, yet the old always-on interval
 * woke the tab twice a second for its whole life (CLE-35075). The first row
 * starts the clock, the last row leaving stops it; rows expire exactly as
 * before because every row is pushed through the queue, and a push emits.
 *
 * @returns stop
 */
export function tickWhileShown(
  queue: { tick(): boolean, items(): unknown[], subscribe(fn: (items: unknown[]) => void): () => void },
  timers: { every?: (fn: () => void, ms: number) => unknown, cancel?: (id: unknown) => void } = {},
): () => void {
  const every = timers.every || ((fn: () => void, ms: number): unknown => setInterval(fn, ms))
  const cancel = timers.cancel || ((id: unknown) => clearInterval(id as ReturnType<typeof setInterval>))
  let id: unknown = null
  function sync(items: unknown[]) {
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
 * @returns unbind
 */
export function bindSnackbarToJournal(
  queue: SnackbarQueue,
  journal: {
    getErrors: () => unknown[]
    subscribeErrors: (fn: (r: unknown[]) => void) => () => void
    now?: () => number
  },
): () => void {
  const now = typeof journal.now === 'function' ? journal.now : () => Date.now()
  let lastSeq = 0
  const seqOf = (r: JournalRec | null | undefined): number => (r && Number.isFinite(Number(r.seq)) ? Number(r.seq) : 0)

  function take(records: unknown, replay: boolean) {
    for (const r of (Array.isArray(records) ? records : []) as JournalRec[]) {
      const s = seqOf(r)
      if (s <= lastSeq) continue
      lastSeq = s
      // SPL-1833: the page already says this one in place (search errors)
      if (r.inline === true) continue
      if (replay) {
        const at = Date.parse(String(r.at || ''))
        if (!Number.isFinite(at) || now() - at > SNACKBAR_REPLAY_MS) continue
      }
      queue.push(r)
    }
  }

  let initial: unknown[] = []
  try { initial = journal.getErrors() } catch { initial = [] }
  take(initial, true)
  // clearErrors() empties the buffer; the journal's seq never goes back, so
  // the next record is still above lastSeq.
  return journal.subscribeErrors((records) => take(records, false))
}
