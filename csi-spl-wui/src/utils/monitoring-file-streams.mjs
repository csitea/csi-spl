// csi-spl-wui/src/utils/monitoring-file-streams.mjs
//
// Spec 160 3.5 (SPL-3888, row B5; the list, SPL-4124 row B8): Monitoring ->
// File streams, every box's followed files as a list, each with its own
// tail -f button that opens that file live. The page (pages/monitoring/file-streams/index.vue) and the
// lazy client (spool-client-lazy.mjs getFileStreams / getFileStreamLines /
// fileStreamGlobs) are the only importers: this module never reaches the initial bundle.
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
  return fileStreamRowsOf(body, 'streams')
}

/**
 * The same answer's `removed` (spec 160 3.10, SPL-4979): the files taken out of
 * the view, which a Put back returns; an older hub sends none.
 * @param {unknown} body
 */
export function fileStreamsRemovedOf(body) {
  return fileStreamRowsOf(body, 'removed')
}

/** One list of GET /v1/view/file-streams, parsed and sorted. */
function fileStreamRowsOf(body, list) {
  const rows = body && typeof body === 'object' && Array.isArray(/** @type {any} */ (body)[list]) ? /** @type {any} */ (body)[list] : []
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

/**
 * The list (C39): one group per box, in order, its streams by key. With the
 * glob list (3.8, row B12) a box that has only globs or announced folders
 * is a group too, and each group carries its globs and folders. So is a box
 * with only removed files (3.10), each group carrying them too.
 * @param {ReturnType<typeof fileStreamsOf>} streams
 * @param {ReturnType<typeof fileStreamGlobsOf>} [globs]
 * @param {ReturnType<typeof fileStreamsOf>} [removed]
 */
export function fileStreamGroupsOf(streams, globs = { globs: [], folders: [] }, removed = []) {
  const gl = globs || { globs: [], folders: [] }
  const boxes = [...new Set([...fileStreamBoxes(streams), ...fileStreamBoxes(removed), ...gl.globs.map((g) => g.boxId), ...gl.folders.map((f) => f.boxId)])].sort()
  return boxes.map((boxId) => ({
    boxId,
    streams: (streams || []).filter((s) => s.boxId === boxId),
    globs: gl.globs.filter((g) => g.boxId === boxId),
    folders: gl.folders.filter((f) => f.boxId === boxId),
    removed: (removed || []).filter((s) => s.boxId === boxId),
  }))
}

/* ---- file globs typed in the page (spec 160 3.8, row B12, SPL-4695) ---- */
// The routes (3.8.3, built in row B9): GET /v1/view/file-streams/globs,
// POST /v1/file-streams/globs {box_id, key, glob}, DELETE
// /v1/file-streams/globs/{id}, GET /v1/view/file-streams/globs/audit, behind
// the read routes' gate (owner or admin of the workspace). The hub only
// checks, stores and audits a glob; the box expands it (row B10). A glob's
// state comes only from the box's announce: `pending` until the box reports
// it, so the page never says "following" before the box does (3.8.1).

/** The glob states (3.8.6) and pending (stored, not yet reported by the box). */
export const FS_GLOB_STATES = Object.freeze(['pending', 'following', 'partial', 'none', 'refused'])
/** The hub's refusal codes of an add or a remove that have their own sentence (3.8.3, 3.8.8). */
export const FS_GLOB_ERRORS = Object.freeze(['bad_glob', 'bad_key', 'outside_folders', 'glob_key_taken', 'too_many_globs', 'box_locked', 'not_found', 'forbidden'])
/** The audit actions (3.8.9, and a file's remove and put back, 3.10). */
export const FS_GLOB_ACTIONS = Object.freeze(['add', 'remove', 'refused', 'file_remove', 'file_restore'])
/** A glob's key (3.8.3): 24 at most, so a match key fits 3.2's 32. */
const FS_GLOB_KEY_RE = /^[a-z0-9][a-z0-9-]{0,23}$/
/** The audit rows the page shows (3.8.9: the newest 50). */
export const FS_GLOB_AUDIT_PAGE = 50

const int0 = (v) => (Number.isSafeInteger(v) && v > 0 ? v : 0)
const str = (v) => (typeof v === 'string' ? v : '')

/**
 * GET /v1/view/file-streams/globs -> the live globs (by box, then key) and
 * the folders each box announced (by box, then path); a row without an id
 * or a box is dropped. An unknown state reads as pending: never following.
 * @param {unknown} body
 */
export function fileStreamGlobsOf(body) {
  const b = /** @type {any} */ (body && typeof body === 'object' ? body : {})
  const globs = (Array.isArray(b.globs) ? b.globs : [])
    .filter((g) => g && typeof g.id === 'string' && g.id && BOX_RE.test(String(g.box_id || '')))
    .map((g) => ({
      id: String(g.id),
      boxId: String(g.box_id),
      key: str(g.key),
      glob: str(g.glob),
      state: FS_GLOB_STATES.includes(g.state) ? String(g.state) : 'pending',
      reason: str(g.reason),
      matched: int0(g.matched),
      followed: int0(g.followed),
      overCap: int0(g.over_cap),
      reportedAt: str(g.reported_at),
      createdAt: str(g.created_at),
    }))
    .sort((x, y) => (x.boxId === y.boxId ? x.key.localeCompare(y.key) : x.boxId.localeCompare(y.boxId)))
  const folders = (Array.isArray(b.folders) ? b.folders : [])
    .filter((f) => f && BOX_RE.test(String(f.box_id || '')) && typeof f.path === 'string' && f.path)
    .map((f) => ({ boxId: String(f.box_id), path: String(f.path), state: f.state === 'allowed' ? 'allowed' : 'refused', reason: str(f.reason) }))
    .sort((x, y) => (x.boxId === y.boxId ? x.path.localeCompare(y.path) : x.boxId.localeCompare(y.boxId)))
  return { globs, folders }
}

/** The text key of a glob's state (3.8.6); pending for anything else. */
export function fileStreamGlobStateKey(state) {
  return 'monitoring.file_streams.glob.state.' + (FS_GLOB_STATES.includes(state) ? state : 'pending')
}

/** Whether a glob row shows "N of M matches followed": only once the box reported matches. */
export function fileStreamGlobCounted(g) {
  return Boolean(g) && (g.state === 'following' || g.state === 'partial') && g.matched > 0
}

/**
 * The POST body of an add (C55): {box_id, key, glob} and nothing else; the
 * key trimmed, the glob as typed (the hub and the box check it).
 */
export function fileStreamGlobBody(boxId, key, glob) {
  return { box_id: String(boxId || ''), key: String(key || '').trim(), glob: String(glob ?? '') }
}

/** The text key of a refused add or remove: its code's sentence, else the generic one. */
export function fileStreamGlobErrorKey(err) {
  const e = /** @type {any} */ (err || {})
  const code = typeof e.token === 'string' && FS_GLOB_ERRORS.includes(e.token) ? e.token : e.status === 403 ? 'forbidden' : e.status === 404 ? 'not_found' : 'other'
  return 'monitoring.file_streams.glob.err.' + code
}

/** The text key of a refused remove or put back of a file (3.10); the generic sentence is the globs'. */
export function fileStreamRowErrorKey(err) {
  const e = /** @type {any} */ (err || {})
  if (e.token === 'box_locked') return 'monitoring.file_streams.file.err.box_locked'
  if (e.status === 404) return 'monitoring.file_streams.file.err.not_found'
  if (e.status === 403) return 'monitoring.file_streams.file.err.forbidden'
  return 'monitoring.file_streams.glob.err.other'
}

/**
 * GET .../globs/audit -> the rows, newest first, and the next page's before.
 * @param {unknown} body
 */
export function fileStreamGlobAuditOf(body) {
  const b = /** @type {any} */ (body && typeof body === 'object' ? body : {})
  const rows = (Array.isArray(b.audit) ? b.audit : [])
    .filter((a) => a && typeof a.id === 'string' && a.id && FS_GLOB_ACTIONS.includes(a.action))
    .map((a) => ({ id: String(a.id), globId: str(a.glob_id), boxId: str(a.box_id), action: String(a.action), key: str(a.key), glob: str(a.glob), actor: str(a.actor), reason: str(a.reason), at: str(a.at) }))
    .sort((x, y) => (x.at < y.at ? 1 : x.at > y.at ? -1 : 0))
  return { rows, nextBefore: str(b.next_before) }
}

/** The query of an audit page (?before=&limit=). */
export function fileStreamGlobAuditQuery(q = {}) {
  const p = new URLSearchParams()
  if (q.before) p.set('before', String(q.before))
  if (q.limit) p.set('limit', String(q.limit))
  const s = p.toString()
  return s ? '?' + s : ''
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

/** The mock streams (GET /v1/view/file-streams): a removed one (3.10) moves to `removed`. */
export function mockFileStreams(now = Date.now()) {
  const at = new Date(now).toISOString()
  const all = {
    streams: [
      { id: FS_MOCK_IDS.app, box_id: 'box-a', stream_key: 'app', path: '/var/log/app.log', state: 'following', reason: '', last_line_at: at, last_seq: mockLast(FS_MOCK_IDS.app, now), lines_total: mockLast(FS_MOCK_IDS.app, now), lines_dropped: 0, lines_kept: 0 },
      { id: FS_MOCK_IDS.cron, box_id: 'box-a', stream_key: 'cron', path: '/var/log/cron.log', state: 'following', reason: '', last_line_at: at, last_seq: mockLast(FS_MOCK_IDS.cron, now), lines_total: mockLast(FS_MOCK_IDS.cron, now), lines_dropped: 0, lines_kept: 0 },
      { id: FS_MOCK_IDS.web, box_id: 'box-b', stream_key: 'web', path: '/var/log/web.log', state: 'missing', reason: 'not_found', last_line_at: null, last_seq: 0, lines_total: 0, lines_dropped: 0, lines_kept: 0 },
    ],
  }
  const gone = mockGlobState(now).removedFiles
  return {
    streams: all.streams.filter((s) => !gone[s.id]),
    removed: all.streams.filter((s) => gone[s.id]).map((s) => ({ ...s, state: 'gone', reason: '', removed_at: gone[s.id] })),
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

/* ---- the glob mock: the hub's checks of 3.8.3 over an in-page store ---- */

export const FS_MOCK_GLOB_IDS = Object.freeze({ syslog: '1a6b3d2f-7c8e-4f90-8a1b-2c3d4e5f6a70', web: '1a6b3d2f-7c8e-4f90-8a1b-2c3d4e5f6a71' })
const FS_MOCK_GLOBS_PER_BOX = 8
let mockGlobs = null

/** The mock's folders (as two boxes would announce them) and two globs: one the box reported, one pending. */
function mockGlobState(now) {
  if (mockGlobs) return mockGlobs
  const at = new Date(now).toISOString()
  mockGlobs = {
    seq: 0,
    folders: [
      { box_id: 'box-a', path: '/var/csi/csi-spl', state: 'allowed', reason: '', reported_at: at },
      { box_id: 'box-a', path: '/var/log', state: 'allowed', reason: '', reported_at: at },
      { box_id: 'box-a', path: '/etc', state: 'refused', reason: 'fewer than two segments', reported_at: at },
      { box_id: 'box-b', path: '/var/log', state: 'allowed', reason: '', reported_at: at },
    ],
    globs: [
      { id: FS_MOCK_GLOB_IDS.syslog, box_id: 'box-a', key: 'syslog', glob: '/var/log/*.log', created_by: 'HUM-1', created_at: at,
        state: 'partial', reason: '', matched: 12, followed: 5, over_cap: 7, reported_at: at, removed: false },
      { id: FS_MOCK_GLOB_IDS.web, box_id: 'box-b', key: 'web-old', glob: '/var/log/web/*.log', created_by: 'HUM-1', created_at: at,
        state: 'pending', reason: '', matched: 0, followed: 0, over_cap: 0, reported_at: null, removed: false },
    ],
    audit: [],
    removedFiles: /** @type {Record<string, string>} */ ({}),
  }
  for (const g of mockGlobs.globs) mockAudit(mockGlobs, { glob_id: g.id, box_id: g.box_id, action: 'add', key: g.key, glob: g.glob, reason: '' }, now - 60000)
  return mockGlobs
}

function mockAudit(st, row, now) {
  st.seq += 1
  st.audit.push({ id: `2b7c4e3a-8d9f-4a01-9b2c-${String(st.seq).padStart(12, '0')}`, actor: 'HUM-1', glob_id: '', ...row, at: new Date(now).toISOString() })
}

const mockErr = (status, token, detail) => Object.assign(new Error(detail), { status, token, detail })

/** wire.CheckFileStreamGlob (3.8.3) in the mock: '' when the glob passes, else why. */
export function mockGlobSyntax(g) {
  const s = String(g ?? '')
  if (!s || new TextEncoder().encode(s).length > 512) return 'a glob is 1..512 bytes'
  if (/\p{Cc}/u.test(s)) return 'a glob is one line with no control character'
  if (/[[{]/.test(s)) return "'[' and '{' are not glob syntax here"
  if (s.includes('**')) return "'**' is refused"
  const rest = s.startsWith('$HOME/') ? s.slice(6) : s.startsWith('/') ? s.slice(1) : null
  if (rest === null) return 'a glob is absolute or starts $HOME/'
  const segs = rest.split('/')
  for (let i = 0; i < segs.length; i++) {
    if (segs[i] === '' || segs[i] === '.' || segs[i] === '..') return "no empty, '.' or '..' segment"
    if (i < segs.length - 1 && /[*?]/.test(segs[i])) return "'*' and '?' only in the last segment"
  }
  return ''
}

/** wire.FileStreamGlobUnder: the glob's literal directory is the folder or under it. */
function mockGlobUnder(g, folder) {
  const i = g.lastIndexOf('/')
  const dir = i <= 0 ? '/' : g.slice(0, i)
  const f = folder.replace(/\/+$/, '')
  return Boolean(f) && (dir === f || dir.startsWith(f + '/'))
}

/** The mock's GET /v1/view/file-streams/globs. */
export function mockFileStreamGlobs(now = Date.now()) {
  const st = mockGlobState(now)
  return {
    globs: st.globs.filter((g) => !g.removed).map(({ removed: _removed, ...g }) => g),
    folders: st.folders.map((f) => ({ ...f })),
  }
}

/** The hub's refusal of an add, in its order (3.8.3, 5.10), or null. */
function mockGlobRefusal(st, b) {
  const box = String(b.box_id || '')
  const live = st.globs.filter((g) => !g.removed && g.box_id === box)
  const allowed = st.folders.filter((f) => f.box_id === box && f.state === 'allowed').map((f) => f.path)
  const syntax = mockGlobSyntax(b.glob)
  if (syntax) return [400, 'bad_glob', syntax]
  if (!FS_GLOB_KEY_RE.test(String(b.key || ''))) return [400, 'bad_key', 'key must match ' + FS_GLOB_KEY_RE.source]
  if (!allowed.some((f) => mockGlobUnder(String(b.glob), f))) return [400, 'outside_folders', `the glob's directory is under none of the box's allowed folders (${allowed.join(', ') || 'none'})`]
  if (live.some((g) => g.key === b.key)) return [409, 'glob_key_taken', 'a live glob of this box has that key']
  if (live.length >= FS_MOCK_GLOBS_PER_BOX) return [409, 'too_many_globs', `the box holds ${FS_MOCK_GLOBS_PER_BOX} live globs, its cap`]
  return null
}

/**
 * The mock's POST /v1/file-streams/globs: the body exactly {box_id, key,
 * glob} (the hub's strict decoder), a box of the mock, then the checks.
 * Every refusal but bad_key is an audit row. `json` is the body as sent.
 * @param {string} json
 */
export function mockAddFileStreamGlob(json, now = Date.now()) {
  const st = mockGlobState(now)
  /* the bodies as sent, for the e2e (C55: {box_id, key, glob} only) */
  const rec = /** @type {{ SPOOL_MOCK_FS_GLOB_POSTS?: string[] }} */ (globalThis)
  rec.SPOOL_MOCK_FS_GLOB_POSTS = [...(rec.SPOOL_MOCK_FS_GLOB_POSTS || []), String(json)]
  let b = null
  try { b = JSON.parse(String(json)) } catch { /* below */ }
  if (!b || typeof b !== 'object' || Object.keys(b).some((k) => !['box_id', 'key', 'glob'].includes(k))) {
    throw mockErr(400, 'bad_request', 'invalid JSON body (expected {"box_id", "key", "glob"})')
  }
  const box = String(b.box_id || '')
  if (!st.folders.some((f) => f.box_id === box)) throw mockErr(404, 'not_found', 'no such box among this workspace\'s file streams')
  const why = mockGlobRefusal(st, b)
  if (why) {
    if (why[1] !== 'bad_key') mockAudit(st, { box_id: box, action: 'refused', key: String(b.key || ''), glob: String(b.glob || ''), reason: why[1] }, now)
    throw mockErr(why[0], why[1], why[2])
  }
  st.seq += 1
  const g = { id: `1a6b3d2f-7c8e-4f90-8a1b-${String(st.seq).padStart(12, '0')}`, box_id: box, key: String(b.key), glob: String(b.glob), created_by: 'HUM-1',
    created_at: new Date(now).toISOString(), state: 'pending', reason: '', matched: 0, followed: 0, over_cap: 0, reported_at: null, removed: false }
  st.globs.push(g)
  mockAudit(st, { glob_id: g.id, box_id: box, action: 'add', key: g.key, glob: g.glob, reason: '' }, now)
  const { removed: _removed, ...out } = g
  return out
}

/** The mock's DELETE /v1/file-streams/globs/{id}: 404 for a glob not live, with no audit row (3.8.8). */
export function mockRemoveFileStreamGlob(id, now = Date.now()) {
  const st = mockGlobState(now)
  const g = st.globs.find((x) => x.id === String(id) && !x.removed)
  if (!g) throw mockErr(404, 'not_found', 'no such file glob')
  g.removed = true
  mockAudit(st, { glob_id: g.id, box_id: g.box_id, action: 'remove', key: g.key, glob: g.glob, reason: '' }, now)
  return null
}

/** A mock stream by id: the rows mockFileStreams builds, removed or not. */
function mockStreamRow(id, now) {
  const b = mockFileStreams(now)
  return [...b.streams, ...b.removed].find((s) => s.id === String(id))
}

/** The mock's DELETE /v1/file-streams/{id} (3.10): 404 for a row not listed, with no audit row. */
export function mockRemoveFileStream(id, now = Date.now()) {
  const st = mockGlobState(now)
  const s = mockStreamRow(id, now)
  if (!s || st.removedFiles[s.id]) throw mockErr(404, 'not_found', 'no such file stream')
  st.removedFiles[s.id] = new Date(now).toISOString()
  mockAudit(st, { box_id: s.box_id, action: 'file_remove', key: s.stream_key, glob: s.path, reason: '' }, now)
  return null
}

/**
 * The mock's POST /v1/file-streams/{id}/restore (3.10): 404 for a row not
 * removed; on a box in globalThis.SPOOL_MOCK_FS_LOCKED_BOXES 403 box_locked,
 * one refused audit row.
 */
export function mockRestoreFileStream(id, now = Date.now()) {
  const st = mockGlobState(now)
  const s = mockStreamRow(id, now)
  if (!s || !st.removedFiles[s.id]) throw mockErr(404, 'not_found', 'no such file stream')
  if ((/** @type {any} */ (globalThis).SPOOL_MOCK_FS_LOCKED_BOXES || []).includes(s.box_id)) {
    mockAudit(st, { box_id: s.box_id, action: 'refused', key: s.stream_key, glob: s.path, reason: 'box_locked' }, now)
    throw mockErr(403, 'box_locked', 'the box is locked: only its lock owners put a file back on it')
  }
  delete st.removedFiles[s.id]
  mockAudit(st, { box_id: s.box_id, action: 'file_restore', key: s.stream_key, glob: s.path, reason: '' }, now)
  return null
}

/** The mock's GET .../globs/audit: newest first, limit (default 50), before. */
export function mockFileStreamGlobAudit(q = {}, now = Date.now()) {
  const st = mockGlobState(now)
  const limit = Math.min(Math.max(Number(q.limit) || FS_GLOB_AUDIT_PAGE, 1), 500)
  const page = [...st.audit].reverse().filter((a) => !q.before || a.at < q.before).slice(0, limit)
  return { audit: page, ...(page.length === limit ? { next_before: page[limit - 1].at } : {}) }
}

/** Forget the mock's globs (a unit test's fresh start). */
export function mockFileStreamGlobsReset() {
  mockGlobs = null
}
