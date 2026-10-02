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
    if (laterThan(m, c)) {
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
