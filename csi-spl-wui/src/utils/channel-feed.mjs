/** Pure feed helpers. Node tests import this file; Vue stores wrap it. */

import { bodyToHtml } from './code-blocks.mjs'
import { matchesSearch, newestFirst, windowed } from './feed.mjs'

export function topLevel(messages) {
  return messages
    .filter((m) => !m.parent_task_id)
    .slice()
    .sort((a, b) => String(a.ts).localeCompare(String(b.ts)))
}

export function threadOf(messages, parentTaskId) {
  if (!parentTaskId) return []
  return messages
    .filter((m) => m.task_id === parentTaskId || m.parent_task_id === parentTaskId)
    .slice()
    .sort((a, b) => String(a.ts).localeCompare(String(b.ts)))
}

export function replyCount(messages, taskId) {
  return messages.filter((m) => m.parent_task_id === taskId).length
}

export function parseMention(text) {
  const raw = String(text || '')
  const m = raw.match(/^@([A-Z]{2,4}-\d+)\b\s*([\s\S]*)$/)
  if (!m) return { to: '@channel', kind: 'note', body: raw }
  return { to: m[1], kind: 'task', body: m[2] }
}

export function displayName(id, box) {
  if (!id) return 'unknown'
  return box ? `${id}@${box}` : id
}

export function initials(id) {
  const s = String(id || '?')
  const m = s.match(/^([A-Z]{2,4})-(\d+)$/)
  if (m) return m[1].slice(0, 2)
  return s.slice(0, 2).toUpperCase()
}

export function hueFor(id) {
  let h = 0
  for (const ch of String(id || '')) h = (h * 31 + ch.charCodeAt(0)) >>> 0
  return h % 360
}

/**
 * Byte size for a file card. `locale` (optional, the active UI locale) formats
 * the number with that locale's separators; without it the output is unchanged
 * ("2.0 KiB"). The unit symbols are technical and never translated.
 */
export function formatBytes(n, locale) {
  const v = Number(n) || 0
  const fmt = (x, digits) => {
    if (!locale) return digits ? x.toFixed(digits) : String(x)
    try {
      return new Intl.NumberFormat(locale, { minimumFractionDigits: digits, maximumFractionDigits: digits }).format(x)
    } catch {
      return digits ? x.toFixed(digits) : String(x)
    }
  }
  if (v < 1024) return `${fmt(v, 0)} B`
  if (v < 1024 * 1024) return `${fmt(v / 1024, 1)} KiB`
  return `${fmt(v / (1024 * 1024), 1)} MiB`
}

/**
 * HH:MM (UTC) of a message timestamp. `locale` (optional, the active UI
 * locale) formats it the way that locale writes a time of day; without it the
 * output is unchanged (ISO "14:05").
 */
export function formatTs(ts, locale) {
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return String(ts || '')
  if (locale) {
    try {
      return new Intl.DateTimeFormat(locale, { hour: '2-digit', minute: '2-digit', timeZone: 'UTC' }).format(d)
    } catch {
      /* unknown locale tag: fall through to the ISO form */
    }
  }
  return d.toISOString().slice(11, 16)
}

/**
 * Escaped HTML of a body (``` blocks, `inline`, **bold**, @mentions). The feed
 * renders parseBody through MessageBody.vue instead; this string form stays
 * for callers that need one.
 */
export function renderBody(src) {
  return bodyToHtml(src)
}

/** Hub channel slug (channels-v1 §5.1: ^[a-z0-9][a-z0-9-]{0,63}$). */
export function channelSlug(name) {
  return String(name || '')
    .toLowerCase()
    .replace(/^#/, '')
    .replace(/[^a-z0-9-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 64)
}

/** Sidebar retention label: only #alerts is short-lived (spec 005 FR-012, "7 d"). */
export function retentionLabel(row) {
  const d = retentionDays(row)
  return d ? `${d} d` : ''
}

/** The number behind retentionLabel (0 = no label), for a translated "{n} d". */
export function retentionDays(row) {
  const id = String((row && (row.channel_id || row.channel)) || '')
  if (id !== 'alerts') return 0
  const d = Number(row && row.retention_days)
  return Number.isFinite(d) && d > 0 ? d : 7
}

/**
 * Footer connection-health dot (spec 005 FR-012) from the live socket state:
 * ok = open (or the mock tenant, which has no socket), warn = (re)connecting,
 * down = anything else (closed, idle, a config error token).
 */
export function connectionHealth(state) {
  const s = String(state || '')
  if (s === 'open' || s === 'mock') return 'ok'
  if (s === 'connecting' || s === 'reconnecting') return 'warn'
  return 'down'
}

function splitLabel(p) {
  const [id, box] = String(p || '').split('@')
  return { id, box }
}

/**
 * One feed row. A flat v:1 message passes through; a view-v1 §4.3 thread row
 * (live `/v1/view/threads?channel=` or `?dm=true&peer=`) becomes a root card
 * keyed by its task_id, with `count - 1` replies.
 */
export function feedRow(row) {
  const r = row || {}
  if (r.msg_id) return r
  const first = splitLabel((r.participants || [])[0])
  const kinds = Object.entries(r.kinds || {}).sort((a, b) => b[1] - a[1])
  return {
    msg_id: String(r.task_id || ''),
    task_id: String(r.task_id || ''),
    ts: r.first_ts || r.ts || '',
    last_ts: r.last_ts || r.first_ts || '',
    from: first.id || '',
    from_box: first.box,
    to: '',
    kind: kinds.length ? kinds[0][0] : 'note',
    body: String(r.subject || ''),
    channel: r.channel === undefined ? null : r.channel,
    parent_task_id: null,
    files: [],
    count: Math.max(0, (Number(r.count) || 1) - 1),
    thread_row: true,
  }
}

/**
 * One card per v:1 thread (task_id): live listMessages returns flat messages
 * where replies share the root's task_id. Earliest message wins; mock roots
 * already have unique task_ids, so this is a no-op there.
 */
export function rootsByTask(messages) {
  const seen = new Set()
  const out = []
  for (const m of messages || []) {
    const id = m && m.task_id
    if (id && seen.has(id)) continue
    if (id) seen.add(id)
    out.push(m)
  }
  return out
}

/** Replies of one thread: child tasks (parent_task_id) plus in-thread messages (same task_id). */
export function threadReplies(messages, taskId) {
  if (!taskId) return 0
  const same = (messages || []).filter((m) => m.task_id === taskId && !m.thread_row).length
  const row = (messages || []).find((m) => m.thread_row && m.task_id === taskId)
  return replyCount(messages || [], taskId) + (row ? Number(row.count) || 0 : Math.max(0, same - 1))
}

/** Does a live message belong to the open channel or DM? */
export function belongsTo(msg, { channel, peer } = {}) {
  const m = msg || {}
  if (peer) {
    if (m.channel) return false
    const { id, box } = splitLabel(peer)
    const from = m.from === id && (!box || !m.from_box || m.from_box === box)
    const to = m.to === id && (!box || !m.to_box || m.to_box === box)
    return from || to
  }
  if (!channel) return false
  const ch = String(m.channel || '').replace(/^#/, '').toLowerCase()
  const want = String(channel).replace(/^#/, '').toLowerCase()
  return ch === want || (want === 'lobby' && ch === 'general')
}

/**
 * Merge one live WS message into the feed (no poll in live mode). Same
 * msg_id → no-op, except that a confirmed row replaces a `pending` one. A reply to a thread row bumps its count; anything else
 * is appended as a new row. Returns a new array.
 */
export function mergeLive(rows, msg) {
  const m = msg || {}
  const list = rows || []
  if (!m.msg_id) return list
  const same = list.findIndex((r) => r.msg_id === m.msg_id)
  if (same >= 0) {
    /* 013 US7 FR-013: the pushed echo (or ack row) replaces our pending card */
    if (!list[same].pending || m.pending) return list
    const next = list.slice()
    next[same] = m
    return next
  }
  const root = m.parent_task_id || m.task_id
  const i = list.findIndex((r) => r.thread_row && r.task_id === root)
  if (i >= 0) {
    const r = list[i]
    const next = list.slice()
    next[i] = { ...r, count: (r.count || 0) + 1, last_ts: m.ts || r.last_ts }
    return next
  }
  return [...list, m]
}

/**
 * WS subscriptions for the open feed: the hub fans a stored message out only
 * to sockets subscribed to its task_id (wui-live-ws, hub fanoutWUI). `keep`
 * (the lobby task another pane follows on the same socket) is never dropped.
 */
export function followPlan(current, want, keep = '') {
  const have = new Set(current || [])
  const next = new Set((want || []).filter(Boolean))
  return {
    add: [...next].filter((t) => !have.has(t)),
    drop: [...have].filter((t) => !next.has(t) && t !== keep),
  }
}

/**
 * The channel-level WS subscription for the open view (wui-live-ws v0.4): the
 * open channel, none for a DM. Returns what to (un)subscribe and the new state.
 */
export function channelFollow(current, { channel, peer } = {}) {
  const have = String(current || '')
  const want = peer ? '' : String(channel || '').replace(/^#/, '').toLowerCase()
  if (want === have) return { sub: '', unsub: '', next: have }
  return { sub: want, unsub: have, next: want }
}

/** The card for our own live send, built from the hub ack before the echo frame. */
export function rowFromAck(ack, frame, { from = '', channel = null } = {}) {
  const a = ack || {}
  const f = frame || {}
  return {
    msg_id: String(a.msg_id || ''),
    task_id: String(a.task_id || f.task_id || ''),
    ts: a.received_at || new Date().toISOString(),
    received_at: a.received_at,
    cursor: a.cursor,
    from,
    to: f.to || '@channel',
    kind: f.kind || 'note',
    body: String(f.body || ''),
    files: f.files || [],
    channel,
    parent_task_id: null,
  }
}

/**
 * 013 on /channel and /dm (X3): one card per thread root, newest first, the
 * Omnibox `/search` filter, then the first `visible` rows. Storage order is
 * untouched; a live append or an older page only changes what is sorted.
 */
export function channelView(messages, { search = '', visible = 50 } = {}) {
  const roots = rootsByTask(topLevel(messages || []))
  return windowed(newestFirst(roots.filter((m) => matchesSearch(m, search))), visible)
}

/**
 * The DM-level WS subscription for the open view (wui-live-ws v0.5 `peer`):
 * the open DM peer, none for a channel. Same shape as channelFollow.
 */
export function dmFollow(current, { peer } = {}) {
  const have = String(current || '')
  const want = String(peer || '')
  if (want === have) return { sub: '', unsub: '', next: have }
  return { sub: want, unsub: have, next: want }
}

/**
 * Reconnect catch-up (FR-015): a fresh first page merged by msg_id — a thread
 * row is replaced (its count moved on), a new one added; older pages already
 * loaded and pending sends stay.
 */
export function mergePage(rows, incoming) {
  const list = (rows || []).slice()
  const at = new Map(list.map((m, i) => [m.msg_id, i]))
  for (const m of incoming || []) {
    if (!m || !m.msg_id) continue
    const i = at.get(m.msg_id)
    if (i === undefined) {
      at.set(m.msg_id, list.length)
      list.push(m)
    } else if (list[i].thread_row || list[i].pending) {
      list[i] = m
    }
  }
  return list
}
