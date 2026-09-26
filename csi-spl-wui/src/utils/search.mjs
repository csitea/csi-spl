/**
 * 022 top-bar global search — the FIRST-PAINT half of the pure helpers: what
 * the Omnibox (MessageComposer, TopBar) needs while typing (mode, query,
 * path, operator catalogue, autocomplete, help rows). The result half
 * (normalising the hub's response, highlights, paging, targets, the mock
 * matcher) is search-results.mjs, loaded only when a search runs, so it stays
 * out of the initial bundle (027 perf budget, CLE-555 item 20).
 *
 * The WUI never parses the Gmail-style grammar: the hub does (search-v1.md,
 * HUB-SEARCH-API lane). Here we only (a) tell a `/search …` line from a message,
 * (b) autocomplete the operator at the caret from a catalogue, (c) turn the
 * hub's offsets into text segments and (d) normalise the grouped response.
 */

import { filterRosterMentions } from './mention-autocomplete.mjs'

/** from: offers at most this many roster ids, same cap as the operator list. */
const FROM_ROSTER_CAP = 8

/** `/search` or `/s`, then a colon, whitespace, or end of line (case-insensitive). */
const SEARCH_CMD_RE = /^\/(?:search|s)(?::|\s|$)/i

/**
 * Built-in operator catalogue — the offline fallback of search-v1 §6
 * (`GET /v1/view/search/operators`, which the WUI prefers: normalizeOperators).
 * `values` are closed value sets offered after the colon.
 */
/** Canonical kinds first, then the aliases a person actually types. */
const TYPE_VALUES = ['message', 'topic', 'file', 'robot', 'user', 'channel', 'box', 'tenant', 'event', 'issue', 'thread', 'person', 'workspace', 'log', 'issues', 'ticket', 'tickets']

/** Rows the omnibox list shows. The nine kinds fit; a longer prefix narrows the rest. */
export const OP_PICKER_CAP = 12

/** Values the omnibox still offers when an older operators document omits them. */
const REQUIRED_TYPE_VALUES = ['tenant', 'event', 'issue', 'thread', 'person', 'workspace', 'log', 'issues', 'ticket', 'tickets']

/** Issue operators (grammar 1.2). Status and priority are closed; assignee offers me and none; label: is free text. */
function issueOperators() {
  return [
    /* rdb 0054: the owner's statuses and prio 1..5 (the live catalogue from
       /v1/view/search/operators follows the store) */
    { op: 'status:', example: 'status:wip', values: ['eval', 'todo', 'wip', 'diss', 'qas', 'done'] },
    { op: 'prio:', example: 'prio:1', values: ['1', '2', '3', '4', '5'] },
    { op: 'assignee:', example: 'assignee:me', values: ['me', 'none'] },
    { op: 'label:', example: 'label:bug' },
  ]
}

export const SEARCH_OPERATORS = [
  { op: 'from:', example: 'from:CLE-07' },
  { op: 'to:', example: 'to:HUM-1' },
  { op: 'in:', example: 'in:#lobby', values: ['dm'] },
  { op: 'channel:', example: 'channel:#lobby', values: ['dm'] },
  { op: 'is:', values: ['task', 'note', 'result', 'reject', 'root', 'online', 'offline', 'revoked'] },
  { op: 'has:', values: ['file', 'attachment', 'code'] },
  { op: 'type:', values: TYPE_VALUES },
  { op: 'kind:', example: 'kind:message', values: TYPE_VALUES },
  { op: 'before:', example: 'before:2026-09-01' },
  { op: 'after:', example: 'after:7d' },
  { op: 'on:', example: 'on:2026-09-19' },
  { op: 'box:', example: 'box:box-a' },
  { op: 'topic:', example: 'topic:<task id>' },
  { op: 'title:', example: 'title:"release plan"' },
  { op: 'subject:', example: 'subject:migration' },
  { op: 'name:', example: 'name:ops' },
  ...issueOperators(),
  { op: 'filename:', example: 'filename:"q3 report"' },
  { op: 'ext:', example: 'ext:pdf' },
  { op: 'larger:', example: 'larger:1M' },
  { op: 'smaller:', example: 'smaller:10K' },
]

/**
 * Hub catalogue plus the operators a document from before this grammar does
 * not list yet: tenant, event and issue (and their aliases) on type: and
 * kind:, kind: and channel: when the document has type: / in:, and the issue
 * operators status:, priority:, assignee: and label:. A catalogue that
 * already has them is returned unchanged.
 */
export function ensureSearchOperators(catalogue = SEARCH_OPERATORS) {
  const src = Array.isArray(catalogue) && catalogue.length ? catalogue : SEARCH_OPERATORS
  let changed = false
  const out = src.map((o) => {
    if (!o || (o.op !== 'type:' && o.op !== 'kind:') || !Array.isArray(o.values)) return o
    const values = o.values.map(String)
    let add = false
    for (const v of REQUIRED_TYPE_VALUES) {
      if (!values.includes(v)) { values.push(v); add = true }
    }
    if (!add) return o
    changed = true
    return { ...o, values }
  })
  const has = (op) => out.some((o) => o && o.op === op)
  if (!has('kind:') && has('type:')) {
    const type = out.find((o) => o.op === 'type:')
    const values = Array.isArray(type.values) ? type.values.slice() : REQUIRED_TYPE_VALUES.slice()
    out.push({ op: 'kind:', example: 'kind:message', values })
    changed = true
  }
  if (!has('channel:') && has('in:')) {
    const inn = out.find((o) => o.op === 'in:')
    out.push({ op: 'channel:', example: 'channel:#lobby', values: Array.isArray(inn.values) ? inn.values.slice() : ['dm'] })
    changed = true
  }
  for (const extra of issueOperators()) {
    if (!has(extra.op)) { out.push(extra); changed = true }
  }
  return changed ? out : src
}

/** One help row per operator: the token, an example, closed values, an i18n key. */
export function operatorHelpRows(catalogue = SEARCH_OPERATORS) {
  const list = Array.isArray(catalogue) && catalogue.length ? catalogue : SEARCH_OPERATORS
  const rows = []
  for (const o of list) {
    const op = String((o && o.op) || '')
    if (!/^[a-z]+:$/.test(op)) continue
    const values = Array.isArray(o.values) ? o.values.map(String) : []
    const example = o.example ? String(o.example) : (values.length ? op + values[0] : op)
    rows.push({ op, example, values, hintKey: 'search.op.' + op.slice(0, -1) })
  }
  return rows
}

/**
 * Whether TopBar may fetch GET /v1/view/search/operators.
 * Mock hydrates immediately (no hub). Live waits for a member session so a
 * signed-out /channel/lobby does not 401. Same predicate as createShellBootstrap.
 */
export function shouldLoadOperators({ mock, sessionState } = {}) {
  return Boolean(mock) || String(sessionState) === 'in'
}

/** Omnibox mode of a line: 'search' for `/search …`, `/search:…`, `/s …`, else 'send'. */
export function omniboxMode(text) {
  return SEARCH_CMD_RE.test(String(text || '')) ? 'search' : 'send'
}

/**
 * The omnibox line once the reader leaves /search (SPL-13). A search line
 * left behind keeps the omnibox in search mode on every page, and search
 * mode has no Attach and no Send, so it is cleared. A send draft is kept.
 */
export function omniboxTextLeavingSearch(text) {
  return omniboxMode(text) === 'search' ? '' : String(text ?? '')
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
  // `/search:from` has no space, so the word includes the command.
  if (start < m[0].length) start = m[0].length
  if (start >= i) return null
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

