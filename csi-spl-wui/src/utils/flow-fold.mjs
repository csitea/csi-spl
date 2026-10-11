/**
 * Spec 130 (owner HUM-10, t1 da98036e) lane L2a: the Flow answers "what is
 * happening" in folded lines, one per topic per UTC day and one per UTC day
 * of releases. The hub folds (GET /v1/view/flow?fold=day, contract
 * specs/130-flow-what-is-happening/contracts/flow-fold-v1.md); this is the
 * pure half the WUI renders from: the line's key, its parts, where it opens,
 * the read mark opening it writes, and the menu actions it offers. The mock
 * (and a hub that answers `events` only) folds here by the hub's rules.
 * Pure: no Vue, no store.
 */

import { flowText } from './flow-entries.mjs'

/** The strongest kind first (contract 2.1): a line shows its strongest event. */
export const FLOW_LINE_RANK = Object.freeze(['blocked', 'ready', 'mention', 'poke', 'dm', 'reply'])

/** The glyph a line leads with, by kind. */
export const FLOW_LINE_GLYPH = Object.freeze({
  blocked: '⛔',
  ready: '✓',
  mention: '@',
  poke: '@',
  dm: '✉',
  reply: '↳',
  release: '🏷',
})

/** Author ids a line names before "+N" (the hub's flowLineIDs). */
export const FLOW_LINE_IDS = 2

const rank = (k) => {
  const i = FLOW_LINE_RANK.indexOf(String(k || ''))
  return i < 0 ? FLOW_LINE_RANK.length : i
}

/** The UTC day of an RFC 3339 time, '' when it is no time. */
export function utcDay(at) {
  const ms = Date.parse(String(at || ''))
  return Number.isFinite(ms) ? new Date(ms).toISOString().slice(0, 10) : ''
}

/** A line's stable key: a topic-day cut by a page edge stays two keys (its newest msg differs). */
export function flowLineKey(line) {
  if (!line) return ''
  if (line.kind === 'release') return `rel|${line.day}|${line.version_to || ''}`
  return `t|${line.task_id || ''}|${line.day}|${line.msg_id || ''}`
}

/**
 * One wire line, checked and shaped: null for a line the WUI cannot open
 * (no topic and no release). Unknown fields are dropped.
 */
export function parseFlowLine(raw) {
  if (!raw || typeof raw !== 'object') return null
  const kind = String(raw.kind || '')
  const base = {
    kind,
    day: String(raw.day || utcDay(raw.at)),
    count: Math.max(1, Number(raw.count) || 1),
    at: String(raw.at || ''),
    unread: raw.unread === true,
    link: String(raw.link || ''),
    mark: String(raw.mark || ''),
  }
  if (kind === 'release') {
    const to = String(raw.version_to || '')
    const sha = String(raw.sha || '')
    if (!to || !sha) return null
    const versions = Math.max(1, Number(raw.versions) || base.count)
    const line = { ...base, count: versions, version_from: String(raw.version_from || to), version_to: to, versions, sha }
    if (!line.link) line.link = '/releases/' + sha
    if (!line.mark) line.mark = 'f:rel:' + to
    return { ...line, key: flowLineKey(line) }
  }
  const task = String(raw.task_id || '')
  const msg = String(raw.msg_id || '')
  if (!task || !msg) return null
  const line = {
    ...base,
    kind: FLOW_LINE_RANK.includes(kind) ? kind : 'reply',
    task_id: task,
    msg_id: msg,
    channel: raw.channel == null || raw.channel === '' ? null : String(raw.channel),
    parent_task_id: String(raw.parent_task_id || ''),
    title: String(raw.title || ''),
    text: String(raw.text || ''),
    ids: Array.isArray(raw.ids) ? raw.ids.map(String).filter(Boolean) : [],
    ids_more: Math.max(0, Number(raw.ids_more) || 0),
    issue: Math.max(0, Number(raw.issue) || 0),
    hidden: raw.hidden === true,
    /* MOCK / an events-only hub: the DM peer label the fold kept, for the line's place */
    where: String(raw.where || ''),
  }
  if (!line.link) line.link = `/t/${task}#${msg}`
  if (!line.mark) line.mark = 't:' + task
  return { ...line, key: flowLineKey(line) }
}

/** The wire lines, shaped; the ones that cannot open are dropped. */
export function parseFlowLines(raw) {
  return (Array.isArray(raw) ? raw : []).map(parseFlowLine).filter(Boolean)
}

/** Held lines plus a next page's: in order, a key held once (the first wins). */
export function mergeFlowLines(held, more) {
  const seen = new Set()
  const out = []
  for (const l of [...(held || []), ...(more || [])]) {
    if (!l || seen.has(l.key)) continue
    seen.add(l.key)
    out.push(l)
  }
  return out
}

/** The topic-day (or release day) a line folds: two lines of one fold share it. */
function foldOf(l) {
  return l.kind === 'release' ? 'rel|' + l.day : l.task_id + '|' + l.day
}

/**
 * A fresh newest page over the lines held (a live event, a reconnect): the
 * fresh lines first, then every held line whose topic-day the fresh page does
 * not carry, so the older pages read so far stay and a line whose newest
 * event moved is not shown twice.
 */
export function refreshFlowLines(fresh, held) {
  const folds = new Set((fresh || []).map(foldOf))
  return mergeFlowLines(fresh, (held || []).filter((l) => !folds.has(foldOf(l))))
}

/**
 * Fold flow events (newest first, the flow-v1 `events` shape) into topic
 * lines by the hub's rule (contract 2.1): one per (task_id, UTC day), the
 * strongest kind, the count, the newest event's ids and text, up to two
 * author ids newest first then "+N". `titleOf(task_id)` gives the topic's
 * title (its first message's body); `unreadOf(event)` whether one event is
 * unread. The mock answers with it, and so does a hub that sends `events` only.
 */
export function foldFlowEvents(events, { titleOf = () => '', unreadOf = (e) => e.unread !== false } = {}) {
  const lines = new Map()
  const order = []
  for (const e of events || []) {
    const task = String((e && e.task_id) || '')
    const at = String((e && (e.at || e.received_at || e.ts)) || '')
    if (!task || !e.msg_id || !at) continue
    const day = utcDay(at)
    const k = task + '|' + day
    let l = lines.get(k)
    if (!l) {
      l = {
        kind: String(e.kind || 'reply'), day, count: 0, at, unread: false,
        task_id: task, msg_id: String(e.msg_id), channel: e.channel || null, parent_task_id: String(e.parent_task_id || ''),
        title: flowText(titleOf(task) || ''), text: flowText(e.body || e.text || ''),
        from: [], where: String(e.where || ''),
      }
      lines.set(k, l)
      order.push(l)
    }
    l.count++
    if (rank(e.kind) < rank(l.kind)) l.kind = String(e.kind)
    if (unreadOf(e)) l.unread = true
    const who = String(e.from || '')
    if (who && !l.from.includes(who)) l.from.push(who)
  }
  return order.map((l) => {
    const { from, ...rest } = l
    return parseFlowLine({ ...rest, ids: from.slice(0, FLOW_LINE_IDS), ids_more: Math.max(0, from.length - FLOW_LINE_IDS) })
  }).filter(Boolean)
}

/**
 * MOCK ONLY: the mock hub's releases (version, sha, released_at), newest
 * first, folded per UTC day as the hub folds release_notes.released_at.
 */
export const MOCK_RELEASES = Object.freeze([
  Object.freeze({ version: 'v1.3.402', sha: '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c', at: '2026-09-18T09:40:00Z' }),
  Object.freeze({ version: 'v1.3.401', sha: '1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d', at: '2026-09-18T08:10:00Z' }),
  Object.freeze({ version: 'v1.3.400', sha: '2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e', at: '2026-09-18T07:05:00Z' }),
])

/**
 * Fold release rows (newest first) into one release line per UTC day
 * (contract 2.2). A line is unread when it is newer than `seen` (the f:seen
 * time; '' = never seen, so nothing is unread yet) and its f:rel: mark is not
 * set (`marked(version_to)`).
 */
export function foldReleases(rows, { seen = '', marked = () => false } = {}) {
  const days = new Map()
  for (const r of rows || []) {
    const day = utcDay(r.at)
    if (!day) continue
    const l = days.get(day)
    if (!l) days.set(day, { kind: 'release', day, at: r.at, version_to: r.version, version_from: r.version, versions: 1, sha: r.sha })
    else {
      l.version_from = r.version
      l.versions++
    }
  }
  return [...days.values()].map((l) => parseFlowLine({ ...l, unread: Boolean(seen) && l.at > seen && !marked(l.version_to) })).filter(Boolean)
}

/** Lines of both kinds, newest first (the hub merges releases into the topic lines by time). */
export function flowByNewest(lines) {
  return [...(lines || [])].sort((a, b) => String(b.at).localeCompare(String(a.at)))
}

/**
 * Where opening a line goes (spec 130 section 2.4): a release line to its
 * release log, a `blocked` line of a topic with an issue to that issue, any
 * other topic line to its newest message.
 * @returns {{ to: 'release' | 'issue' | 'message', path: string }}
 */
export function flowLineTarget(line) {
  if (!line) return { to: 'message', path: '' }
  if (line.kind === 'release') return { to: 'release', path: '/releases/' + encodeURIComponent(line.sha) }
  if (line.kind === 'blocked' && line.issue > 0) return { to: 'issue', path: '/issues?issue=' + line.issue }
  return { to: 'message', path: line.link }
}

/**
 * The read mark opening a line writes (spec 130 FR-009): `t:<task_id>` at
 * the newest event, covering every event it folds; a release line
 * `f:rel:<version>`. One PUT /v1/me/reads `marks` body.
 */
export function flowLineMark(line) {
  if (!line || !line.mark) return {}
  const ts = line.at || new Date().toISOString()
  return { [line.mark]: line.kind === 'release' ? { ts } : { ts, id: line.msg_id } }
}

/**
 * The ids of the actions (msg-shortcuts.mjs FLOW_LINE_ACTIONS) a line
 * offers, in that table's order: Open discussion on a topic line, Open issue
 * when the topic has one, Open release log on a release line, Copy link and
 * Copy text on every line, Mark read while it is unread.
 */
export function flowLineOffered(line) {
  if (!line) return []
  const out = []
  if (line.kind === 'release') out.push('release')
  else {
    out.push('open')
    if (line.issue > 0) out.push('issue')
  }
  out.push('copy', 'copy-text')
  if (line.unread) out.push('read')
  return out
}
