// csi-spl-wui/src/utils/monitoring-file-streams.mjs
//
// Spec 160 3.5 (SPL-3888, row B5; the list, SPL-4124 row B8): Monitoring ->
// File streams, every box's followed files as a list, each with its own
// tail -f button that opens that file live. The page (pages/monitoring/file-streams/index.vue) and the
// lazy client (spool-client-lazy.mjs getFileStreams / getFileStreamLines)
// are the only importers: this module never reaches the initial bundle.
// The routes (3.4): GET /v1/view/file-streams and
// GET /v1/view/file-streams/{id}/lines?after=|before=&limit=, for the
// workspace's owner or an admin; anyone else gets 403.

/** The poll while the tab is visible and not paused (decision D3: no socket). */
export const FS_POLL_MS = 3000
/** At most this many lines in the view; the oldest go first. */
export const FS_VIEW_MAX = 2000
/** A page of lines: the hub's cap (3.4). */
export const FS_PAGE = 1000
/** The first page of a stream, and the lines around a search hit. */
export const FS_FIRST = 200

const BOX_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/i
const KEY_RE = /^[a-z0-9][a-z0-9-]{0,31}$/

/**
 * GET /v1/view/file-streams -> the streams, sorted by box then key; a row
 * that is not a stream (no id, junk box or key) is dropped.
 * @param {unknown} body
 * @returns {{ id: string, boxId: string, streamKey: string, path: string, state: string, reason: string, lastSeq: number, lastLineAt: string, linesTotal: number, linesKept: number }[]}
 */
export function fileStreamsOf(body) {
  const rows = body && typeof body === 'object' && Array.isArray(/** @type {any} */ (body).streams) ? /** @type {any} */ (body).streams : []
  return rows
    .filter((r) => r && typeof r.id === 'string' && r.id && BOX_RE.test(String(r.box_id || '')) && KEY_RE.test(String(r.stream_key || '')))
    .map((r) => ({
      id: r.id,
      boxId: String(r.box_id),
      streamKey: String(r.stream_key),
      path: typeof r.path === 'string' ? r.path : '',
      state: typeof r.state === 'string' ? r.state : '',
      reason: typeof r.reason === 'string' ? r.reason : '',
      lastSeq: Number.isSafeInteger(r.last_seq) ? r.last_seq : 0,
      lastLineAt: typeof r.last_line_at === 'string' ? r.last_line_at : '',
      linesTotal: Number.isSafeInteger(r.lines_total) ? r.lines_total : 0,
      linesKept: Number.isSafeInteger(r.lines_kept) ? r.lines_kept : 0,
    }))
    .sort((a, b) => (a.boxId === b.boxId ? a.streamKey.localeCompare(b.streamKey) : a.boxId.localeCompare(b.boxId)))
}

/** The boxes that have a stream, in order. */
export function fileStreamBoxes(streams) {
  return [...new Set((streams || []).map((s) => s.boxId))]
}

/** The list (C39): one group per box, in order, its streams by key. */
export function fileStreamGroupsOf(streams) {
  return fileStreamBoxes(streams).map((boxId) => ({ boxId, streams: streams.filter((s) => s.boxId === boxId) }))
}

/**
 * The open file from the URL (?box=&stream=&seq=): only a box and a stream
 * the hub returned, else none, so nothing opens before a tail -f click and
 * a typed path never does (C40); seq only when a positive integer (a search
 * hit: Follow starts off, 3.6).
 * @param {Record<string, unknown>} query
 * @param {ReturnType<typeof fileStreamsOf>} streams
 * @returns {{ box: string, stream: string, id: string, seq: number }}
 */
export function fileStreamOpenOf(query, streams) {
  const q = query || {}
  const one = (v) => String((Array.isArray(v) ? v[0] : v) ?? '')
  const s = (streams || []).find((x) => x.boxId === one(q.box) && x.streamKey === one(q.stream))
  if (!s) return { box: '', stream: '', id: '', seq: 0 }
  const seq = Number(one(q.seq))
  return { box: s.boxId, stream: s.streamKey, id: s.id, seq: Number.isSafeInteger(seq) && seq > 0 ? seq : 0 }
}

/** The query of an open file, for router.push (seq only for a search hit). */
export function fileStreamQuery(box, stream, seq = 0) {
  const out = /** @type {Record<string, string>} */ ({})
  if (box) out.box = box
  if (stream) out.stream = stream
  if (seq > 0) out.seq = String(seq)
  return out
}

/**
 * GET .../lines -> the lines, oldest first.
 * @param {unknown} body
 * @returns {{ seq: number, at: string, text: string, marker: boolean }[]}
 */
export function fileStreamLinesOf(body) {
  const rows = body && typeof body === 'object' && Array.isArray(/** @type {any} */ (body).lines) ? /** @type {any} */ (body).lines : []
  return rows
    .filter((l) => l && Number.isSafeInteger(l.seq) && l.seq > 0)
    .map((l) => ({ seq: l.seq, at: typeof l.at === 'string' ? l.at : '', text: typeof l.text === 'string' ? l.text : '', marker: l.marker === true }))
    .sort((a, b) => a.seq - b.seq)
}

/**
 * The view after adding lines: one row per seq, oldest first, at most max
 * (the oldest dropped).
 */
export function mergeFileStreamLines(cur, add, max = FS_VIEW_MAX) {
  const by = new Map()
  for (const l of cur || []) by.set(l.seq, l)
  for (const l of add || []) by.set(l.seq, l)
  const out = [...by.values()].sort((a, b) => a.seq - b.seq)
  return out.length > max ? out.slice(out.length - max) : out
}

/** The newest seq in the view (0 for none): the next poll's after=. */
export function lastSeqOf(lines) {
  return lines && lines.length ? lines[lines.length - 1].seq : 0
}

/** Find in view (3.5): the loaded lines holding needle, case-insensitive; all for none. */
export function filterFileStreamLines(lines, needle) {
  const n = String(needle || '').trim().toLowerCase()
  return n ? (lines || []).filter((l) => l.text.toLowerCase().includes(n)) : (lines || [])
}

/** Whether the view sits at its bottom (within slack px): Follow stays on. */
export function atBottom(el, slack = 8) {
  return !el || el.scrollTop + el.clientHeight >= el.scrollHeight - slack
}

/**
 * The poll: load() every FS_POLL_MS while the browser tab is visible and the
 * view is not paused; a paused or hidden view makes no request (C19).
 * @param {{ load: () => void, visibility: () => string, paused: () => boolean, setTimer?: (fn: () => void, ms: number) => unknown, clearTimer?: (h: unknown) => void }} o
 */
export function startFileStreamPoll(o) {
  const setTimer = o.setTimer || ((fn, ms) => setInterval(fn, ms))
  const clearTimer = o.clearTimer || ((h) => clearInterval(/** @type {any} */ (h)))
  let handle = setTimer(() => {
    if (o.visibility() === 'visible' && !o.paused()) o.load()
  }, FS_POLL_MS)
  return {
    stop: () => {
      if (handle !== null) clearTimer(handle)
      handle = null
    },
  }
}

/* ---- the mock (the lde and e2e bundle): two boxes, three streams, a line appended per poll ---- */

export const FS_MOCK_IDS = Object.freeze({ app: '0f5a2c1e-6b7d-4e8f-9a0b-1c2d3e4f5a60', cron: '0f5a2c1e-6b7d-4e8f-9a0b-1c2d3e4f5a61', web: '0f5a2c1e-6b7d-4e8f-9a0b-1c2d3e4f5a62' })
const FS_MOCK_BASE = 60
let mockStart = 0

/** The mock streams (GET /v1/view/file-streams). */
export function mockFileStreams(now = Date.now()) {
  const at = new Date(now).toISOString()
  return {
    streams: [
      { id: FS_MOCK_IDS.app, box_id: 'box-a', stream_key: 'app', path: '/var/log/app.log', state: 'following', reason: '', last_line_at: at, last_seq: mockLast(FS_MOCK_IDS.app, now), lines_total: mockLast(FS_MOCK_IDS.app, now), lines_dropped: 0, lines_kept: 0 },
      { id: FS_MOCK_IDS.cron, box_id: 'box-a', stream_key: 'cron', path: '/var/log/cron.log', state: 'following', reason: '', last_line_at: at, last_seq: mockLast(FS_MOCK_IDS.cron, now), lines_total: mockLast(FS_MOCK_IDS.cron, now), lines_dropped: 0, lines_kept: 0 },
      { id: FS_MOCK_IDS.web, box_id: 'box-b', stream_key: 'web', path: '/var/log/web.log', state: 'missing', reason: 'not_found', last_line_at: null, last_seq: 0, lines_total: 0, lines_dropped: 0, lines_kept: 0 },
    ],
  }
}

/** The last seq of a mock stream now: app grows by one line per FS_POLL_MS since the first read. */
function mockLast(id, now) {
  if (!mockStart) mockStart = now
  if (id === FS_MOCK_IDS.web) return 0
  return id === FS_MOCK_IDS.app ? FS_MOCK_BASE + Math.floor((now - mockStart) / FS_POLL_MS) : 12
}

/**
 * The mock lines of a stream (GET .../lines): after (oldest first), before
 * (the newest below it) or the newest; every 20th line is a marker.
 * @param {string} id
 * @param {{ after?: number, before?: number, limit?: number }} q
 */
export function mockFileStreamLines(id, q = {}, now = Date.now()) {
  if (!Object.values(FS_MOCK_IDS).includes(id)) throw Object.assign(new Error('no such file stream'), { status: 404, token: 'not_found' })
  const last = mockLast(id, now)
  const limit = Math.min(Math.max(Number(q.limit) || FS_FIRST, 1), FS_PAGE)
  let from
  let to
  if (q.after !== undefined) { from = Number(q.after) + 1; to = Math.min(last, from + limit - 1) } else {
    to = q.before !== undefined ? Math.min(last, Number(q.before) - 1) : last
    from = Math.max(1, to - limit + 1)
  }
  const key = id === FS_MOCK_IDS.app ? 'app' : 'cron'
  const lines = []
  for (let s = from; s <= to; s++) {
    const marker = s % 20 === 0
    lines.push({ seq: s, at: new Date(now - (last - s) * FS_POLL_MS).toISOString(), marker,
      text: marker ? `[rotated] ${key}.log` : `${s % 7 === 0 ? 'WARN' : 'INFO'} ${key} mock line ${s}` })
  }
  return { lines }
}
