/**
 * 022 top-bar global search — the RESULT half of the pure helpers, split from
 * search.mjs so it stays out of the initial bundle (027 perf budget; CLE-555
 * item 20). pages/search.vue imports it statically (a lazy page chunk);
 * spool-client.mjs and the search store import it dynamically, when a search
 * or an operators load actually runs. Nothing on the first paint may import
 * this file statically.
 *
 * (c) turn the hub's offsets into text segments, (d) normalise the grouped
 * response, page it, and resolve a row's target; plus the lde mock matcher.
 */

import { SEARCH_OPERATORS, searchPath } from './search.mjs'
import { parentSection, parentSectionHref } from './parent-section.mjs'

/** Result sections in render order (spec 022 FR-021; group keys of search-v1 §4).
 *  tenants, events and issues are opt-in: the hub returns them for type:tenant,
 *  type:event and type:issue. */
export const SEARCH_GROUPS = ['robots', 'users', 'channels', 'boxes', 'tenants', 'topics', 'files', 'messages', 'events', 'issues']

/**
 * Canonical type names, then each type's aliases. `type:` completions lead
 * with tenant and event; aliases such as thread and person narrow by typing.
 */
function typeNamesOf(data) {
  const types = Array.isArray(data && data.types) ? data.types : []
  const canonical = []
  const aliases = []
  const seen = new Set()
  const add = (bucket, raw) => {
    const s = String(raw || '').toLowerCase()
    if (!/^[a-z][a-z0-9]*$/.test(s) || seen.has(s)) return
    seen.add(s)
    bucket.push(s)
  }
  for (const t of types) {
    add(canonical, t && t.type)
    for (const a of (Array.isArray(t && t.aliases) ? t.aliases : [])) add(aliases, a)
  }
  return canonical.concat(aliases)
}

/**
 * search-v1 §6 operators document → the catalogue shape above. Aliases become
 * their own entries; `type:` values come from `types[]` (canonical, then
 * aliases); an enum's keys are its values. Junk → the built-in catalogue.
 */
export function normalizeOperators(data) {
  const d = data && typeof data === 'object' ? data : {}
  if (!Array.isArray(d.operators) || !d.operators.length) return SEARCH_OPERATORS
  const typeNames = typeNamesOf(d)
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
    const last = merged.at(-1)
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
  if (v && typeof v === 'object' && !Array.isArray(v)) {
    const highlights = Array.isArray(v.highlights) ? v.highlights : (Array.isArray(v.hl) ? v.hl : [])
    return { text: String(v.text ?? ''), highlights }
  }
  if (typeof v === 'string') return { text: v, highlights: [] }
  return null
}

/** The highlighted text of a row: message `snippet`, topic `title`, else `name` (search-v1 §4). */
function displayOf(r) {
  return textOf(r.snippet) || textOf(r.title) || textOf(r.name) || textOf(r.display_name)
    || (typeof r.message === 'string' && r.message ? { text: r.message, highlights: [] } : null)
    || { text: String(r.body || r.id || r.key || r.box_id || r.channel || r.task_id || r.error_id || r.tenant_id || ''), highlights: [] }
}

function keyOf(type, r, i) {
  // The list key overwrites r.key. An issue is identified by that field, not by task_id.
  if (type === 'issues') {
    const k = String(r.key ?? '').trim()
    return `issues:${k || i}`
  }
  const id = r.msg_id || r.file_id || r.task_id || r.box_id || r.channel || r.tenant_id || r.event_id || r.error_id || r.id || i
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
      items: rows.filter((r) => r && typeof r === 'object').map((r, i) => {
        const row = { ...r, type, key: keyOf(type, r, i), display: displayOf(r) }
        if (type === 'issues') row.issue_key = String(r.key ?? '').trim()
        return row
      }),
    })
  }
  const warnings = (Array.isArray(d.warnings) ? d.warnings : []).map((w) =>
    typeof w === 'string'
      ? { token: '', pos: -1, detail: w }
      : { token: String((w && w.token) || ''), pos: Number.isInteger(w && w.pos) ? w.pos : -1, detail: String((w && (w.detail || w.message)) || '') })
  return { query: String(d.query || ''), groups: groups.filter((g) => g.items.length), warnings }
}

/**
 * the clock a search row is ordered by, whatever its group: a message
 * its received_at, a topic its last_at, a channel its last_ts, a box its last
 * hello. Stamped on the row as data-ts so the rendered order can be audited
 * against the clock (the hub answers each group newest first, search-v1 §4).
 */
export function rowAt(row) {
  const r = row || {}
  return String(r.received_at || r.last_at || r.last_ts || r.last_hello_at || r.created_at || r.at || '')
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
 * FR-023: where a row goes. → { topic, focus } for the topic pane,
 * { path } for a route (locale prefix is the caller's), or { search } for a
 * follow-up query (a box → its messages).
 */
export function searchTarget(row) {
  const r = row || {}
  switch (r.type) {
    case 'messages':
      return r.task_id ? { topic: String(r.parent_task_id || r.task_id), focus: r.msg_id ? String(r.msg_id) : '' } : null
    case 'topics':
      return r.task_id ? { topic: String(r.task_id), focus: '' } : null
    case 'files':
      return r.task_id ? { topic: String(r.task_id), focus: r.msg_id ? String(r.msg_id) : '' } : null
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
    case 'tenants': {
      const id = String(r.tenant_id || '').trim()
      return id && !/[\s/#?]/.test(id) ? { tenant: id } : null
    }
    case 'events': {
      const n = Number(r.event_id != null ? r.event_id : r.id)
      if (!Number.isInteger(n) || n <= 0) return { path: '/events' }
      return { path: `/events#${n}` }
    }
    case 'issues': {
      const raw = Object.prototype.hasOwnProperty.call(r, 'issue_key') ? r.issue_key : r.key
      const key = String(raw ?? '').trim()
      if (!key) return null
      return { path: `/issues?issue=${encodeURIComponent(key)}` }
    }
    default:
      return null
  }
}

/**
 * 022 §10: a hit that was POSTED somewhere - a message, a topic,
 * a file. Its original is the DM or channel it lives in, not the row's own
 * page, and it also has a preview in the search page's right pane.
 */
export function isPlacedRow(row) {
  const t = row && row.type
  return t === 'messages' || t === 'topics' || t === 'files'
}

/**
 * FR-050: the right menu of a search row. Open original first (it is also
 * the click, FR-051), Show here for a posted hit, Copy link when the original
 * has an address.
 *
 * @param {unknown} row
 * @returns {{ id: 'original' | 'here' | 'copy', icon: string, labelKey: string }[]}
 */
export function searchRowMenuItems(row) {
  const r = row && typeof row === 'object' ? row : {}
  if (!searchTarget(r)) return []
  const items = [{ id: 'original', icon: 'open', labelKey: 'search.menu.original' }]
  if (isPlacedRow(r)) items.push({ id: 'here', icon: 'messages', labelKey: 'search.menu.here' })
  if (!('tenant' in searchTarget(r))) items.push({ id: 'copy', icon: 'copy', labelKey: 'search.menu.copy_link' })
  return items
}

/**
 * The topic page of a posted hit, the fallback original when the row cannot
 * name its DM or channel (a DM topic carries no peer; a file sent by the
 * reader names only the reader). The message id is the hash.
 */
export function topicPageOf(row) {
  const r = row && typeof row === 'object' ? row : {}
  const task = String(r.parent_task_id || r.task_id || '')
  if (!task) return ''
  const id = r.type === 'topics' ? '' : String(r.msg_id || '')
  return '/t/' + encodeURIComponent(task) + (id ? '#' + id : '')
}

/**
 * FR-051: the address of a row's original, as Copy link gives it. A posted
 * hit: its channel or DM with ?topic= and #<msg_id> (utils/parent-section.mjs,
 * the Open parent section rule), else its topic page. An issue discussion
 * copies the topic page (the Issues tab alone would not name the issue).
 * Any other row: its FR-023 page. A tenant row has no address ('').
 *
 * @param {unknown} row
 * @param {{ self?: string, pathFor?: (path: string) => string }} [opts]
 */
export function originalHref(row, opts = {}) {
  const o = opts && typeof opts === 'object' ? opts : {}
  const pathFor = typeof o.pathFor === 'function' ? o.pathFor : (p) => p
  const r = row && typeof row === 'object' ? row : {}
  if (isPlacedRow(r)) {
    const msg = r.type === 'topics' ? { ...r, msg_id: '' } : r
    const section = parentSection(msg, { self: String(o.self || '') })
    if (section && section.kind !== 'issue') return parentSectionHref(section, pathFor)
    const page = topicPageOf(r)
    if (!page) return ''
    const [path, hash] = page.split('#')
    return String(pathFor(path) || path) + (hash ? '#' + hash : '')
  }
  const to = searchTarget(r)
  if (!to || 'tenant' in to) return ''
  if ('path' in to) {
    const [path, hash] = to.path.split('#')
    return String(pathFor(path) || path) + (hash ? '#' + hash : '')
  }
  if ('search' in to) return String(pathFor(searchPath(to.search)))
  return ''
}

/**
 * Mock-mode matcher (FR-026, lde only): free words (AND, case-insensitive)
 * over body, plus `from:` `to:` `in:` `is:`. Anything else is ignored with a
 * warning — the real grammar is the hub's.
 */
export function mockSearch(messages, q, channels = []) {
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
  /* the hub's channel section (t1 2b15a748): free words only, over the id,
     the name and `#id` */
  const chans = filters.length || !words.length ? [] : (channels || []).filter((c) => {
    const id = String((c && (c.channel_id || c.channel)) || '')
    const hay = [id, String((c && c.name) || ''), '#' + id].map((x) => x.toLowerCase())
    return id && words.every((w) => hay.some((h) => h.includes(w)))
  }).map((c) => {
    const id = String(c.channel_id || c.channel)
    const w = words.map((x) => x.replace(/^#/, '')).find((x) => x && id.toLowerCase().includes(x)) || ''
    const at = w ? id.toLowerCase().indexOf(w) : -1
    return { channel: id, default: false, count: (messages || []).filter((m) => m.channel === id).length, last_ts: null,
      name: { text: id, highlights: at >= 0 ? [[at, at + w.length]] : [] } }
  })
  return { query: String(q || ''), sort: 'newest', types: ['message', 'channel'], warnings,
    groups: { messages: { results, next: null }, channels: { results: chans, next: null } } }
}
