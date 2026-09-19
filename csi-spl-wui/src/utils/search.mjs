/**
 * 022 top-bar global search — pure helpers. Node tests import this file; the
 * Omnibox (MessageComposer), the search store and pages/search.vue wrap it.
 *
 * The WUI never parses the Gmail-style grammar: the hub does (search-v1.md,
 * HUB-SEARCH-API lane). Here we only (a) tell a `/search …` line from a message,
 * (b) autocomplete the operator at the caret from a catalogue, (c) turn the
 * hub's offsets into text segments and (d) normalise the grouped response.
 */

/** `/search` or `/s`, then whitespace or end of line (case-insensitive). */
const SEARCH_CMD_RE = /^\/(?:search|s)(?=\s|$)/i

/** Result sections in render order (spec 022 FR-021). */
export const SEARCH_GROUPS = ['robots', 'users', 'threads', 'files', 'channels', 'messages']

/**
 * Operator catalogue for autocomplete — mirrors search-v1.md. `values` are the
 * closed value sets offered after the colon; open operators carry an example.
 */
export const SEARCH_OPERATORS = [
  { op: 'from:', example: 'from:CLE-07' },
  { op: 'to:', example: 'to:HUM-1' },
  { op: 'in:', example: 'in:#lobby', values: ['dm'] },
  { op: 'is:', values: ['task', 'note', 'result', 'reject'] },
  { op: 'has:', values: ['file', 'code', 'attachment'] },
  { op: 'type:', values: ['robot', 'user', 'thread', 'file', 'channel', 'message'] },
  { op: 'before:', example: 'before:2026-09-01' },
  { op: 'after:', example: 'after:7d' },
  { op: 'on:', example: 'on:2026-09-19' },
  { op: 'box:', example: 'box:box-a' },
  { op: 'thread:', example: 'thread:<task id>' },
  { op: 'title:', example: 'title:"deploy plan"' },
  { op: 'name:', example: 'name:EZB' },
  { op: 'filename:', example: 'filename:report' },
  { op: 'ext:', example: 'ext:pdf' },
  { op: 'larger:', example: 'larger:1M' },
  { op: 'smaller:', example: 'smaller:100K' },
  { op: 'online:', values: ['true', 'false'] },
]

/** Omnibox mode of a line: 'search' for `/search …` / `/s …`, else 'send'. */
export function omniboxMode(text) {
  return SEARCH_CMD_RE.test(String(text || '')) ? 'search' : 'send'
}

/** The raw query after `/search` — verbatim apart from the outer whitespace. */
export function searchQueryOf(text) {
  const s = String(text || '')
  const m = s.match(SEARCH_CMD_RE)
  if (!m) return ''
  return s.slice(m[0].length).trim()
}

/** Deep link for a query (FR-020). An empty query links the help view. */
export function searchPath(q) {
  const s = String(q || '').trim()
  return s ? `/search?q=${encodeURIComponent(s)}` : '/search'
}

/** Query string of `GET /v1/view/search` — `q` goes up raw, never rewritten. */
export function searchApiQuery({ q = '', cursor = '', limit = 0 } = {}) {
  const p = new URLSearchParams()
  p.set('q', String(q || ''))
  if (cursor) p.set('cursor', String(cursor))
  if (limit) p.set('limit', String(limit))
  return p.toString()
}

/**
 * The search token under the caret, or null. Only in search mode and only
 * past the `/search ` command; a leading `-` (negation) or `(` is not part of
 * the token. → { token, start, end } with start/end offsets into `text`.
 */
export function operatorTokenAt(text, caret) {
  const s = String(text || '')
  const m = s.match(SEARCH_CMD_RE)
  if (!m) return null
  const n = Number(caret)
  const i = Number.isFinite(n) ? Math.max(0, Math.min(s.length, n)) : s.length
  if (i <= m[0].length) return null
  const before = s.slice(0, i)
  const w = before.match(/[^\s]*$/)
  let start = i - (w ? w[0].length : 0)
  if (start < m[0].length) return null
  while (start < i && (s[start] === '-' || s[start] === '(')) start++
  let end = i
  while (end < s.length && !/\s/.test(s[end]) && s[end] !== ')') end++
  const token = s.slice(start, end)
  // inside a "quoted phrase" there is nothing to complete
  const quotes = (s.slice(m[0].length, start).match(/"/g) || []).length
  if (quotes % 2 === 1 || token.startsWith('"')) return null
  return { token, start, end }
}

/**
 * Completions for a token: an operator-name prefix → operators; `op:` + value
 * prefix → the operator's closed values. → [{ insert, label }]
 */
export function completeOperators(token, catalogue = SEARCH_OPERATORS) {
  const t = String(token || '').toLowerCase()
  if (!t) return []
  const colon = t.indexOf(':')
  if (colon === -1) {
    return catalogue
      .filter((o) => o.op.startsWith(t))
      .map((o) => ({ insert: o.op, label: o.example || o.op + (o.values ? o.values.join('|') : '') }))
  }
  const op = catalogue.find((o) => o.op === t.slice(0, colon + 1))
  if (!op || !op.values) return []
  const v = t.slice(colon + 1)
  return op.values
    .filter((x) => x.startsWith(v) && x !== v)
    .map((x) => ({ insert: op.op + x + ' ', label: op.op + x }))
}

/** Replace the token span with the completion; caret after it. */
export function applyCompletion(text, tok, insert) {
  const s = String(text || '')
  const next = s.slice(0, tok.start) + insert + s.slice(tok.end)
  return { text: next, cursor: tok.start + insert.length }
}

function pairOf(h) {
  if (Array.isArray(h)) return [Number(h[0]), Number(h[1])]
  if (h && typeof h === 'object') {
    if (h.start !== undefined) return [Number(h.start), Number(h.end)]
    if (h.offset !== undefined) return [Number(h.offset), Number(h.offset) + Number(h.length)]
  }
  return [NaN, NaN]
}

/**
 * Snippet text + match offsets → [{ text, mark }] (FR-022). Offsets are
 * clamped, reversed / empty / non-numeric ones dropped, overlaps merged. The
 * result is rendered as text nodes, so markup in `text` stays text.
 */
export function highlightSegments(text, highlights) {
  const s = String(text ?? '')
  const spans = (Array.isArray(highlights) ? highlights : [])
    .map(pairOf)
    .filter(([a, b]) => Number.isFinite(a) && Number.isFinite(b))
    .map(([a, b]) => [Math.max(0, Math.min(s.length, a)), Math.max(0, Math.min(s.length, b))])
    .filter(([a, b]) => b > a)
    .sort((x, y) => x[0] - y[0])
  const merged = []
  for (const [a, b] of spans) {
    const last = merged[merged.length - 1]
    if (last && a <= last[1]) last[1] = Math.max(last[1], b)
    else merged.push([a, b])
  }
  const out = []
  let at = 0
  for (const [a, b] of merged) {
    if (a > at) out.push({ text: s.slice(at, a), mark: false })
    out.push({ text: s.slice(a, b), mark: true })
    at = b
  }
  if (at < s.length || !out.length) out.push({ text: s.slice(at), mark: false })
  return out
}

function snippetOf(r) {
  if (r && r.snippet && typeof r.snippet === 'object') {
    return { text: String(r.snippet.text ?? ''), highlights: r.snippet.highlights || [] }
  }
  if (r && typeof r.snippet === 'string') return { text: r.snippet, highlights: r.highlights || [] }
  return { text: String((r && (r.body || r.title || r.subject || r.name)) ?? ''), highlights: (r && r.highlights) || [] }
}

function keyOf(type, r, i) {
  const id = r.msg_id || r.task_id || r.file_id || r.channel_id || r.id || i
  return `${type}:${id}${r.box ? '@' + r.box : ''}`
}

/**
 * Hub response → { query, groups: [{ type, items }], warnings, next }. Accepts
 * `groups{…}` (multi-entity) or a flat `results[]` (messages only).
 */
export function normalizeSearchResponse(data) {
  const d = data && typeof data === 'object' ? data : {}
  const src = d.groups && typeof d.groups === 'object' ? d.groups : { messages: d.results || d.messages || [] }
  const groups = []
  for (const type of SEARCH_GROUPS) {
    const rows = Array.isArray(src[type]) ? src[type] : []
    if (!rows.length) continue
    groups.push({
      type,
      items: rows.map((r, i) => ({ ...r, type, key: keyOf(type, r, i), snippet: snippetOf(r) })),
    })
  }
  const warnings = (Array.isArray(d.warnings) ? d.warnings : []).map((w) =>
    typeof w === 'string' ? { token: '', message: w } : { token: String(w.token || ''), message: String(w.message || w.detail || '') })
  return { query: String(d.query || ''), groups, warnings, next: d.next_cursor || d.next || null }
}

/** Every row of every group, in render order — the keyboard walks this. */
export function flattenGroups(groups) {
  return (groups || []).flatMap((g) => g.items)
}

/** FR-024: the next active index for a key over `n` rows (wrapping). */
export function moveIndex(i, n, key) {
  if (!n) return -1
  const cur = Number.isInteger(i) && i >= 0 && i < n ? i : -1
  switch (key) {
    case 'ArrowDown': return (cur + 1) % n
    case 'ArrowUp': return cur <= 0 ? n - 1 : cur - 1
    case 'Home': return 0
    case 'End': return n - 1
    default: return cur
  }
}

/**
 * FR-023: where a row goes. → { thread, focus } for the thread pane, or
 * { path } for a route (locale prefix is the caller's).
 */
export function searchTarget(row) {
  const r = row || {}
  switch (r.type) {
    case 'messages':
      return r.task_id ? { thread: String(r.parent_task_id || r.task_id), focus: r.msg_id ? String(r.msg_id) : '' } : null
    case 'threads':
      return r.task_id ? { thread: String(r.task_id), focus: '' } : null
    case 'files':
      return r.task_id ? { thread: String(r.task_id), focus: r.msg_id ? String(r.msg_id) : '' } : null
    case 'robots':
    case 'users': {
      const id = String(r.id || '')
      return id ? { path: `/dm/${encodeURIComponent(r.box ? `${id}@${r.box}` : id)}` } : null
    }
    case 'channels': {
      const id = String(r.channel_id || r.id || '').replace(/^#/, '')
      return id ? { path: `/channel/${encodeURIComponent(id)}` } : null
    }
    default:
      return null
  }
}

/**
 * Mock-mode matcher (FR-026, lde only): free words (AND, case-insensitive)
 * over body, plus `from:` `to:` `in:` `is:`. Anything else is ignored with a
 * warning — the real grammar is the hub's.
 */
export function mockSearch(messages, q) {
  const words = []
  const filters = []
  const warnings = []
  for (const raw of String(q || '').match(/"[^"]*"|\S+/g) || []) {
    const m = raw.match(/^([a-z]+):(.*)$/i)
    if (m && ['from', 'to', 'in', 'is'].includes(m[1].toLowerCase())) filters.push([m[1].toLowerCase(), m[2].toLowerCase()])
    else if (m && SEARCH_OPERATORS.some((o) => o.op === m[1].toLowerCase() + ':')) warnings.push({ token: raw, message: 'mock: ignored' })
    else words.push(raw.replace(/^"|"$/g, '').toLowerCase())
  }
  const ok = (msg) => filters.every(([k, v]) => {
    if (k === 'from') return String(msg.from || '').toLowerCase() === v || `${msg.from}@${msg.from_box}`.toLowerCase() === v
    if (k === 'to') return String(msg.to || '').toLowerCase() === v
    if (k === 'is') return String(msg.kind || '').toLowerCase() === v
    if (v === 'dm') return !msg.channel
    return String(msg.channel || '').toLowerCase() === v.replace(/^#/, '')
  })
  const results = []
  for (const msg of messages || []) {
    const body = String(msg.body || '')
    const low = body.toLowerCase()
    if (!ok(msg) || !words.every((w) => low.includes(w))) continue
    const highlights = []
    for (const w of words) {
      if (!w) continue
      for (let at = low.indexOf(w); at !== -1; at = low.indexOf(w, at + w.length)) highlights.push([at, at + w.length])
    }
    results.push({ ...msg, created_at: msg.ts, snippet: { text: body, highlights } })
  }
  results.sort((a, b) => String(b.ts).localeCompare(String(a.ts)))
  return { query: String(q || ''), warnings, next_cursor: null, groups: { messages: results } }
}
