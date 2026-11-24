/**
 * CLE-77930 (owner, t1 bf737f3f): unread is "for me and me only ... not the
 * new messages which I have seen". The read cursors (read-cursor.mjs) live in
 * one browser's localStorage, so a line read on the phone stayed new on the
 * desktop. This keeps them on the hub too (rdb 0098, GET/PUT /v1/me/reads):
 *
 *   pull   GET the member's marks and move every local cursor forward to them
 *          (a later ts wins; a thread's seen count takes the higher)
 *   push   PUT the ch:/t:/dm: cursors that moved since the last exchange,
 *          every PUSH_MS while the tab is open and whenever it is hidden
 *
 * The hub never rewinds a mark, so two tabs pushing in any order converge.
 * A lazy chunk started from the feed pages (027: nothing in the initial
 * chunk); its own failures are silent - the local cursors still work alone.
 */

import { loadCursors, saveCursors } from './read-cursor.mjs'

export const PUSH_MS = 5000
const MAX_MARKS = 200
const KEY = /^(ch|t|dm):\S{1,200}$/

function at(ts) {
  const n = Date.parse(String(ts || ''))
  return Number.isFinite(n) ? n : -Infinity
}

/** a is later than b: by time, then by msg id (the hub's (at, msg_id) order). */
export function laterThan(a, b) {
  if (!b || !b.ts) return Boolean(a && a.ts)
  if (!a || !a.ts) return false
  const d = at(a.ts) - at(b.ts)
  return d > 0 || (d === 0 && String(a.id || '') > String(b.id || ''))
}

/**
 * ap-05: the hub's answer to this tab's own PUT of a channel read (cursorFromChannel
 * keeps no msg id) comes back at the same time with the id filled in. That is
 * not a new mark: taking it moved the key, reloaded the channel list, and the
 * reload reset the id to '' for the next PUT - one GET per PUT, every 5 s.
 */
function idEcho(m, c) {
  return Boolean(c && c.ts && !c.id && at(m.ts) === at(c.ts))
}

/**
 * Local cursors moved forward to the hub's marks. Returns the same object
 * and an empty list when nothing moved.
 *
 * @param {Record<string, any>} cursors
 * @param {Record<string, { ts?: string, id?: string, cursor?: string, count?: number }>} marks
 * @returns {{ cursors: Record<string, any>, moved: string[] }}
 */
export function mergeMarks(cursors, marks) {
  let out = cursors || {}
  const moved = []
  for (const [k, m] of Object.entries(marks || {})) {
    if (!KEY.test(k) || !m || !m.ts) continue
    const c = out[k]
    let next = c ? { ...c } : { ts: '', id: '' }
    let changed = false
    if (laterThan(m, c) && !idEcho(m, c)) {
      next.ts = String(m.ts)
      next.id = String(m.id || '')
      if (m.cursor) next.hub = String(m.cursor)
      else delete next.hub
      changed = true
    }
    const count = Number(m.count)
    if (Number.isFinite(count) && count > 0 && !(Number(next.count) >= count)) {
      next.count = count
      changed = true
    }
    if (!changed) continue
    if (out === cursors) out = { ...(cursors || {}) }
    out[k] = next
    moved.push(k)
  }
  return { cursors: out, moved }
}

/** The msg id inside a view-v1 cursor (base64url "<ts>|<msg_id>"), or ''. */
function cursorId(cur) {
  try {
    const s = atob(String(cur || '').replace(/-/g, '+').replace(/_/g, '/'))
    const i = s.indexOf('|')
    return i < 0 ? '' : s.slice(i + 1)
  } catch {
    return ''
  }
}

/** The cursor is at or past the channel row's newest message; a same-ms tie counts only on the same msg id. */
function coversRow(c, row) {
  if (!c || !c.ts || !row || !row.last_ts) return false
  const d = at(c.ts) - at(row.last_ts)
  return d > 0 || (d === 0 && Boolean(c.id) && String(c.id) === cursorId(row.last_cursor))
}

/**
 * p20-06 (SPL-6428): which moved ch: keys need the channel list read again.
 * prd, n=1 session: a channel page re-sent its row cursor (the newest
 * message, markChannelRead) every 5 s, the PUT's answer carried a later
 * wall-clock mark of the same member, the key moved, and every move reloaded
 * the whole list - whose watch ran markChannelRead and rewound it again. The
 * answer cannot say which tab or device wrote that mark, so the rule does not
 * ask: a moved key whose cursor is at or past its row's newest message has
 * nothing unread, wherever the read came from. It stays in place (`inPlace`)
 * when its local count is already 0. Anything else still reloads: a key with
 * no row, a cursor before the row's newest message (read partway elsewhere),
 * or a local count above 0 (a live message may be newer than the row).
 *
 * @param {string[]} moved
 * @param {Record<string, any>} cursors the merged local cursors
 * @param {Array<{ channel_id?: string, channel?: string, last_ts?: string | null, last_cursor?: string | null }>} rows
 * @param {Record<string, number>} [counts] the key's local badge counts (unread + mentions)
 * @returns {{ inPlace: string[], reload: boolean }}
 */
export function channelMoves(moved, cursors, rows, counts = {}) {
  const inPlace = []
  let reload = false
  for (const k of moved || []) {
    if (!k.startsWith('ch:')) continue
    const id = k.slice(3)
    const row = (rows || []).find((r) => r && (r.channel_id || r.channel) === id)
    if (coversRow((cursors || {})[k], row) && !(Number(counts[k]) > 0)) inPlace.push(k)
    else reload = true
  }
  return { inPlace, reload }
}

/** One local cursor on the wire (hub wireReadMark). */
export function wireMark(c) {
  const w = { ts: String(c.ts) }
  if (c.id) w.id = String(c.id)
  if (c.hub) w.cursor = String(c.hub)
  if (Number.isFinite(c.count) && c.count > 0) w.count = Number(c.count)
  return w
}

/**
 * The cursors that changed since `sent` (key -> the JSON last exchanged), at
 * most MAX_MARKS, newest first so a long backlog sends what matters.
 */
export function pendingMarks(cursors, sent) {
  const rows = []
  for (const [k, c] of Object.entries(cursors || {})) {
    if (!KEY.test(k) || !c || !c.ts || !Number.isFinite(at(c.ts))) continue
    const w = wireMark(c)
    if (sent[k] === JSON.stringify(w)) continue
    rows.push([k, w])
  }
  rows.sort((a, b) => at(b[1].ts) - at(a[1].ts))
  return Object.fromEntries(rows.slice(0, MAX_MARKS))
}

/**
 * The sync loop. `api` is the spool client (base, token, credentials, mock);
 * `onMoved(keys, marks)` runs after every answer: the keys whose local cursor
 * moved, and the hub's marks.
 *
 * @param {{ base: string, token?: string, credentials?: RequestCredentials }} api
 * @param {{ onMoved?: (moved: string[], marks: Record<string, any>) => void, fetchFn?: typeof fetch, store?: any }} [opts]
 * @returns {{ pull: () => Promise<string[]>, push: () => Promise<void>, ready: Promise<string[]>, stop: () => void }}
 */
export function createReadSync(api, { onMoved = (_moved, _marks) => {}, fetchFn = globalThis.fetch, store } = {}) {
  const sent = {}
  let busy = false
  function req(opts = {}) {
    const headers = { accept: 'application/json', ...(opts.body ? { 'content-type': 'application/json' } : {}) }
    if (api.token) headers.authorization = `Bearer ${api.token}`
    return fetchFn(`${api.base}/v1/me/reads`, { credentials: api.credentials, cache: 'no-store', ...opts, headers })
  }
  async function take(res) {
    if (!res || !res.ok) return []
    const body = await res.json()
    const marks = (body && body.marks) || {}
    const { cursors, moved } = mergeMarks(loadCursors(store), marks)
    if (moved.length) saveCursors(cursors, store)
    for (const [k, m] of Object.entries(marks)) {
      const c = cursors[k]
      if (c && !laterThan(c, m) && !(Number(c.count) > Number(m.count || 0))) sent[k] = JSON.stringify(wireMark(c))
    }
    onMoved(moved, marks)
    return moved
  }
  async function pull() {
    try {
      return await take(await req())
    } catch {
      return []
    }
  }
  async function push() {
    if (busy) return
    const marks = pendingMarks(loadCursors(store), sent)
    if (!Object.keys(marks).length) return
    busy = true
    try {
      await take(await req({ method: 'PUT', body: JSON.stringify({ marks }), keepalive: true }))
    } catch {
      /* the next tick retries: nothing was recorded as sent */
    } finally {
      busy = false
    }
  }
  const ready = pull()
  const timer = setInterval(() => void push(), PUSH_MS)
  const onVis = () => {
    if (typeof document === 'undefined') return
    if (document.hidden) void push()
    else void pull()
  }
  if (typeof document !== 'undefined') document.addEventListener('visibilitychange', onVis)
  return {
    pull,
    push,
    ready,
    stop() {
      clearInterval(timer)
      if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', onVis)
    },
  }
}
