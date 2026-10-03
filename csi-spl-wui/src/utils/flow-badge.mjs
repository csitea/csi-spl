/**
 * Spec 062 (owner, t1 25826b7b): the Flow lists only what concerns the
 * viewer (Mine), with one Facebook-like number on the Flow tab. The hub
 * counts (FR-008): this module only reads its `counts`, shows them, and keeps
 * the Mine / All choice. Pure, no Vue; loaded lazily with the Flow store.
 *
 * Contract (spec 3.2 / 4.2):
 *   GET /v1/view/flow?limit=&before=&kind=   { events, next, counts, unread?, keys? }
 *   GET /v1/view/flow?counts_only=true       { counts, unread?, keys? }
 *   WS  { type: 'flow', counts, unread?, keys?, event: <thin entry> | null }
 *   PUT /v1/me/reads  marks f:seen (the pane opened) and f:<msg_id> (an entry opened)
 */

import { mentionedIds } from './notify.mjs'
import { isViewersOwn } from './typed-by.mjs'

/** The three kinds the badge counts and the chips filter on; a poke folds into mention (Q5). */
export const FLOW_KINDS = Object.freeze(['mention', 'reply', 'dm'])
/** Mine (the default, Q1) or All (today's stream). */
export const FLOW_SCOPES = Object.freeze(['mine', 'all'])
/** The choice per browser until the hub keeps it as a view pref. */
export const FLOW_SCOPE_KEY = 'spool.flow-scope'
/** The read_marks key the pane's opening writes (spec 2.4). */
export const FLOW_SEEN_KEY = 'f:seen'

/** One of FLOW_SCOPES exactly, else Mine. */
export function parseFlowScope(raw) {
  return FLOW_SCOPES.includes(raw) ? raw : FLOW_SCOPES[0]
}

/** An event's kind as the chips see it: a poke counts as its mention. */
export function flowEventKind(kind) {
  const k = String(kind || '')
  if (k === 'poke') return 'mention'
  return FLOW_KINDS.includes(k) ? k : ''
}

function whole(v) {
  const n = Math.floor(Number(v))
  return Number.isFinite(n) && n > 0 ? n : 0
}

/**
 * The hub's counts, cleaned: whole numbers, a `poke` folded into `mention`,
 * `total` the hub's own when it sends one, else the sum. Null for no counts.
 * @returns {{ mention: number, reply: number, dm: number, total: number } | null}
 */
export function parseFlowCounts(raw) {
  if (!raw || typeof raw !== 'object') return null
  const out = { mention: whole(raw.mention) + whole(raw.poke), reply: whole(raw.reply), dm: whole(raw.dm), total: 0 }
  out.total = raw.total === undefined ? out.mention + out.reply + out.dm : whole(raw.total)
  /* the split by a channel line / a DM, when the hub sends it (t1 f4e6c677) */
  if (raw.channels !== undefined || raw.dms !== undefined) {
    out.channels = whole(raw.channels)
    out.dms = whole(raw.dms)
  }
  return out
}

/**
 * Owner (t1 f4e6c677): the red numbers on the Channels and Direct messages
 * tabs - the new messages only in the discussions the viewer takes part in,
 * which is the Flow's own unread set split by where the line is. Null from
 * a hub that does not split (the tabs keep their pip).
 * @returns {{ channels: number, dms: number } | null}
 */
export function railFromUnread(unread) {
  if (!unread || unread.channels === undefined) return null
  return { channels: whole(unread.channels), dms: whole(unread.dms) }
}

/**
 * Owner (t1 77540e6f): a section's unread total is the sum of its rows. The
 * hub's `keys` are the Flow's unread per row - ch:<channel> or dm:<peer>,
 * and t:<task_id> - counted from the same lines as `unread`, so every row
 * badge and every section number reads this one map. Whole counts > 0 only;
 * null from a hub that sends none (the rows keep their own counts).
 * @returns {Record<string, number> | null}
 */
export function parseFlowKeys(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  const out = {}
  for (const [k, v] of Object.entries(raw)) {
    const n = whole(v)
    if (n && /^(ch|dm|t):./.test(k)) out[k] = n
  }
  return out
}

/** The hub's flowPlaceKey: a channel line's channel, a DM's sender as dmPeerOf labels it. */
export function flowPlaceKey(e) {
  const m = e || {}
  if (m.channel) return `ch:${m.channel}`
  return m.from_box ? `dm:${m.from}@${m.from_box}` : `dm:${m.from || ''}`
}

/**
 * MOCK ONLY: the hub's `keys` over `events`: the unopened ones, each once
 * under its place and once under its topic.
 */
export function mockFlowKeys(events, opened = new Set()) {
  const keys = {}
  for (const e of events || []) {
    if (opened.has(String(e.msg_id)) || !flowEventKind(e.kind)) continue
    for (const k of [flowPlaceKey(e), `t:${e.task_id || ''}`]) keys[k] = (keys[k] || 0) + 1
  }
  return parseFlowKeys(keys)
}

/** The tab's number: '' at 0 (hidden), '99+' above 99 (Q3). */
export function badgeLabel(n) {
  const v = whole(n)
  if (!v) return ''
  return v > 99 ? '99+' : String(v)
}

/**
 * The installed app's icon badge (FR-013): setAppBadge(n), clearAppBadge()
 * at 0. Where the browser lacks the API nothing happens. Returns whether it
 * was called.
 */
export function syncAppBadge(nav, n) {
  if (!nav) return false
  const v = whole(n)
  try {
    let p
    if (v && typeof nav.setAppBadge === 'function') p = nav.setAppBadge(v)
    else if (!v && typeof nav.clearAppBadge === 'function') p = nav.clearAppBadge()
    else return false
    if (p && typeof p.catch === 'function') p.catch(() => {})
  } catch {
    return false
  }
  return true
}

/** A thin flow event as a message-shaped row the Flow entries are built from. */
export function eventAsMessage(ev) {
  if (!ev || typeof ev !== 'object') return null
  const files = Array.isArray(ev.files) ? ev.files : Array.from({ length: whole(ev.files) }, () => ({}))
  return { ...ev, body: ev.text !== undefined ? ev.text : ev.body, files }
}

/**
 * MOCK ONLY (the hub counts in live mode, FR-008): the viewer's flow events
 * derived from the mock feed by the spec 2.1 rules - a mention, a DM to me,
 * a reply in a thread I watch (posted in, was mentioned in, or was the `to`
 * of). Never my own line. Returns newest first.
 */
export function mockFlowEvents(messages, self) {
  const me = String(self || '')
  if (!me) return []
  const at = (m) => String((m && (m.received_at || m.ts)) || '')
  const rows = [...(messages || [])].sort((a, b) => at(a).localeCompare(at(b)))
  const watched = new Set()
  const out = []
  for (const m of rows) {
    const task = String(m.task_id || '')
    const named = mentionedIds(m.body).includes(me)
    const toMe = String(m.to || '') === me
    const own = isViewersOwn(m, me)
    let kind = ''
    if (!own) {
      if (named) kind = 'mention'
      else if (!m.channel && toMe) kind = 'dm'
      else if (task && watched.has(task)) kind = 'reply'
    }
    if (task && (own || named || toMe)) watched.add(task)
    if (kind) out.push({ ...m, kind, at: at(m) })
  }
  return out.reverse()
}

/**
 * MOCK ONLY: the counts of `events` newer than `seen` (the f:seen time, ''
 * = never) and not opened (`opened` = msg ids), split by kind.
 */
export function mockFlowCounts(events, seen = '', opened = new Set()) {
  const counts = { mention: 0, reply: 0, dm: 0, channels: 0, dms: 0 }
  for (const e of events || []) {
    if (opened.has(String(e.msg_id))) continue
    if (seen && !(String(e.at) > String(seen))) continue
    const k = flowEventKind(e.kind)
    if (!k) continue
    counts[k]++
    if (e.channel) counts.channels++
    else counts.dms++
  }
  return parseFlowCounts(counts)
}
