/**
 * 022 top-bar global search — pure helpers. Node tests import this file; the
 * Omnibox (MessageComposer), the search store and pages/search.vue wrap it.
 *
 * The WUI never parses the Gmail-style grammar: the hub does (search-v1.md,
 * HUB-SEARCH-API lane). Here we only (a) tell a `/search …` line from a message,
 * (b) autocomplete the operator at the caret from a catalogue, (c) turn the
 * hub's offsets into text segments and (d) normalise the grouped response.
 */

import { filterRosterMentions } from './mention-autocomplete.mjs'

/** from: offers at most this many roster ids, same cap as the operator list. */
const FROM_ROSTER_CAP = 8

/** `/search` or `/s`, then whitespace or end of line (case-insensitive). */
const SEARCH_CMD_RE = /^\/(?:search|s)(?=\s|$)/i

/** Result sections in render order (spec 022 FR-021; group keys of search-v1 §4). */
export const SEARCH_GROUPS = ['robots', 'users', 'channels', 'boxes', 'threads', 'files', 'messages']

/**
 * Built-in operator catalogue — the offline fallback of search-v1 §6
 * (`GET /v1/view/search/operators`, which the WUI prefers: normalizeOperators).
 * `values` are closed value sets offered after the colon.
 */
export const SEARCH_OPERATORS = [
  { op: 'from:', example: 'from:CLE-07' },
  { op: 'to:', example: 'to:HUM-1' },
  { op: 'in:', example: 'in:#lobby', values: ['dm'] },
  { op: 'is:', values: ['task', 'note', 'result', 'reject', 'root', 'online', 'offline', 'revoked'] },
  { op: 'has:', values: ['file', 'attachment', 'code'] },
  { op: 'type:', values: ['message', 'thread', 'file', 'robot', 'user', 'channel', 'box'] },
  { op: 'before:', example: 'before:2026-09-01' },
  { op: 'after:', example: 'after:7d' },
  { op: 'on:', example: 'on:2026-09-19' },
  { op: 'box:', example: 'box:box-a' },
  { op: 'thread:', example: 'thread:<task id>' },
  { op: 'title:', example: 'title:"release plan"' },
  { op: 'subject:', example: 'subject:migration' },
  { op: 'name:', example: 'name:ops' },
  { op: 'filename:', example: 'filename:"q3 report"' },
  { op: 'ext:', example: 'ext:pdf' },
  { op: 'larger:', example: 'larger:1M' },
  { op: 'smaller:', example: 'smaller:10K' },
]

/**
 * search-v1 §6 operators document → the catalogue shape above. Aliases become
 * their own entries; `type:` values come from `types[]`; an enum's keys are
 * its values. Junk → the built-in catalogue.
 */
export function normalizeOperators(data) {
  const d = data && typeof data === 'object' ? data : {}
  if (!Array.isArray(d.operators) || !d.operators.length) return SEARCH_OPERATORS
  const typeNames = (Array.isArray(d.types) ? d.types : []).map((t) => String(t && t.type || '')).filter(Boolean)
  const out = []
  for (const o of d.operators) {
    const name = String((o && o.name) || '').toLowerCase()
    if (!/^[a-z]+$/.test(name)) continue
    let values
    if (o.values === 'type' || name === 'type') values = typeNames.length ? typeNames : undefined
    else if (o.enum && typeof o.enum === 'object') values = Array.isArray(o.enum) ? o.enum.map(String) : Object.keys(o.enum)
    const example = o.example ? String(o.example) : undefined
    for (const n of [name, ...(Array.isArray(o.aliases) ? o.aliases : [])]) {
      const nn = String(n).toLowerCase()
      if (/^[a-z]+$/.test(nn) && !out.some((x) => x.op === nn + ':')) out.push({ op: nn + ':', example, values })
    }
  }
  return out.length ? out : SEARCH_OPERATORS
}

/**
 * Whether TopBar may fetch GET /v1/view/search/operators.
 * Mock hydrates immediately (no hub). Live waits for a member session so a
 * signed-out /channel/lobby does not 401. Same predicate as createShellBootstrap.
 */
export function shouldLoadOperators({ mock, sessionState } = {}) {
  return Boolean(mock) || String(sessionState) === 'in'
}

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
export function searchApiQuery({ q = '', cursor = '', limit = 0, sort = '' } = {}) {
  const p = new URLSearchParams()
  p.set('q', String(q || ''))
  if (sort) p.set('sort', String(sort))
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
 * Completions for a token. The typed text matches any part of the operator,
 * its example, or a closed value, so "task" finds is:task and "file" finds
 * filename: and has:file. A finished closed value (`is:task`) offers nothing.
 * `from:` is open: `roster` is the peer list, matched by filterRosterMentions
 * (contains on the id and the label). Each hit inserts the bare id,
 * `from:CLE-3994 `. A miss invents nothing. `to:` stays closed.
 * → [{ insert, label }]
 */
export function completeOperators(token, catalogue = SEARCH_OPERATORS, roster = []) {
  const t = String(token || '').toLowerCase()
  if (!t) return []
  const colon = t.indexOf(':')
  if (colon === -1) {
    const out = []
    for (const o of catalogue) {
      const name = String(o.op || '').toLowerCase()
      const example = String(o.example || '').toLowerCase()
      const values = Array.isArray(o.values) ? o.values : []
      if (name.includes(t) || example.includes(t)) {
        out.push({ insert: o.op, label: o.example || o.op + (values.length ? values.join('|') : '') })
        continue
      }
      for (const x of values) {
        if (String(x).toLowerCase().includes(t)) out.push({ insert: o.op + x + ' ', label: o.op + x })
      }
    }
    return out
  }
  const op = catalogue.find((o) => o.op === t.slice(0, colon + 1))
  if (op && op.op === 'from:') return fromRosterCompletions(t.slice(colon + 1), roster)
  if (!op || !op.values) return []
  const v = t.slice(colon + 1)
  return op.values
    .filter((x) => String(x).toLowerCase().includes(v) && x !== v)
    .map((x) => ({ insert: op.op + x + ' ', label: op.op + x }))
}

/** Bare ids for an in-progress `from:` value. Same id on two boxes is one row. */
function fromRosterCompletions(query, roster) {
  const hits = filterRosterMentions(roster, query)
  const out = []
  const seen = new Set()
  for (const peer of hits) {
    const id = String((peer && peer.id) || '')
    if (!id || seen.has(id)) continue
    seen.add(id)
    const insert = `from:${id} `
    out.push({ insert, label: insert.trim() })
    if (out.length >= FROM_ROSTER_CAP) break
  }
  return out
}

/**
 * Replace the token span with the completion; caret after it.
 * A completion that already ends in a space does not add a second one when
 * the next character is whitespace. The rest of the line stays as written.
 */
export function applyCompletion(text, tok, insert) {
  const s = String(text || '')
  let put = String(insert || '')
  if (put.endsWith(' ') && tok.end < s.length && /\s/.test(s[tok.end])) put = put.slice(0, -1)
  const next = s.slice(0, tok.start) + put + s.slice(tok.end)
  return { text: next, cursor: tok.start + put.length }
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
 * UTF-16 code units, [start, end) (search-v1 §4) — String.slice units. They are
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

function textOf(v) {
  if (v && typeof v === 'object' && !Array.isArray(v)) return { text: String(v.text ?? ''), highlights: Array.isArray(v.highlights) ? v.highlights : [] }
  if (typeof v === 'string') return { text: v, highlights: [] }
  return null
}

/** The highlighted text of a row: message `snippet`, thread `title`, else `name` (search-v1 §4). */
function displayOf(r) {
  return textOf(r.snippet) || textOf(r.title) || textOf(r.name)
    || { text: String(r.body || r.id || r.box_id || r.channel || r.task_id || ''), highlights: [] }
}

function keyOf(type, r, i) {
  const id = r.msg_id || r.file_id || r.task_id || r.box_id || r.channel || r.id || i
  const extra = type === 'files' ? `/${r.msg_id || ''}/${displayOf(r).text}` : ''
  return `${type}:${id}${r.box ? '@' + r.box : ''}${extra}`
}

/**
 * search-v1 §4 answer → { query, groups: [{ type, items, next }], warnings }.
 * Each group keeps its own `next` cursor (a cursor answers one section). A
 * group given as a bare array, or a flat `results[]`, is accepted too.
 */
export function normalizeSearchResponse(data) {
  const d = data && typeof data === 'object' ? data : {}
  const src = d.groups && typeof d.groups === 'object' ? d.groups : { messages: d.results }
  const groups = []
  for (const type of SEARCH_GROUPS) {
    const g = src[type]
    const rows = Array.isArray(g) ? g : (g && Array.isArray(g.results) ? g.results : [])
    const next = g && !Array.isArray(g) && g.next ? String(g.next) : null
    if (!rows.length) continue
    groups.push({
      type,
      next,
      items: rows.filter((r) => r && typeof r === 'object').map((r, i) => ({ ...r, type, key: keyOf(type, r, i), display: displayOf(r) })),
    })
  }
  const warnings = (Array.isArray(d.warnings) ? d.warnings : []).map((w) =>
    typeof w === 'string'
      ? { token: '', pos: -1, detail: w }
      : { token: String((w && w.token) || ''), pos: Number.isInteger(w && w.pos) ? w.pos : -1, detail: String((w && (w.detail || w.message)) || '') })
  return { query: String(d.query || ''), groups: groups.filter((g) => g.items.length), warnings }
}

/**
 * CLE-3425 — the clock a search row is ordered by, whatever its group: a message
 * its received_at, a thread its last_at, a channel its last_ts, a box its last
 * hello. Stamped on the row as data-ts so the rendered order can be audited
 * against the clock (the hub answers each group newest first, search-v1 §4).
 */
export function rowAt(row) {
  const r = row || {}
  return String(r.received_at || r.last_at || r.last_ts || r.last_hello_at || r.created_at || '')
}

/** A cursor answer (one section) folded into the current result. */
export function mergeSearchPage(cur, page) {
  const groups = (cur && cur.groups ? cur.groups : []).map((g) => ({ ...g }))
  for (const pg of (page && page.groups) || []) {
    const g = groups.find((x) => x.type === pg.type)
    if (!g) { groups.push(pg); continue }
    const seen = new Set(g.items.map((x) => x.key))
    g.items = [...g.items, ...pg.items.filter((x) => !seen.has(x.key))]
    g.next = pg.next
  }
  const order = (t) => SEARCH_GROUPS.indexOf(t)
  groups.sort((a, b) => order(a.type) - order(b.type))
  return { ...(cur || {}), groups }
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
 * FR-023: where a row goes. → { thread, focus } for the thread pane,
 * { path } for a route (locale prefix is the caller's), or { search } for a
 * follow-up query (a box → its messages).
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
    case 'boxes': {
      const id = String(r.box_id || '')
      return id ? { search: `box:${id}` } : null
    }
    case 'robots':
    case 'users': {
      const id = String(r.id || '')
      return id ? { path: `/dm/${encodeURIComponent(r.box ? `${id}@${r.box}` : id)}` } : null
    }
    case 'channels': {
      const id = String(r.channel || r.channel_id || '').replace(/^#/, '')
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
    else if (m && SEARCH_OPERATORS.some((o) => o.op === m[1].toLowerCase() + ':')) warnings.push({ token: raw, detail: 'lde mock: operator ignored' })
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
  return { query: String(q || ''), sort: 'newest', types: ['message'], warnings, groups: { messages: { results, next: null } } }
}
