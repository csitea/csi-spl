/** Pure feed helpers. Node tests import this file; Vue stores wrap it. */

import { bodyToHtml } from './code-blocks.mjs'
import { activityOf, matchesSearch, newestActivityFirst, newestFirst, windowed } from './feed.mjs'

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
  const m = raw.match(/^@([A-Z]{2,4}-\d+)(?:@[a-z0-9][a-z0-9-]{0,31})?\b\s*([\s\S]*)$/)
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
 * output is unchanged (ISO "14:05"). Channel / list cards keep this form.
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
 * CLE-3446 — the owner's settled row format wants a REAL ISO 8601 stamp, with
 * the `T` and the `Z`: `2026-09-22T11:58:03Z`.
 *
 * `formatAbsTs` below is NOT that and must not be bent into it: it returns
 * `yyyy-mm-dd HH:MM:SS`, a space separator and no zone, and other rows read it.
 * It is nearly right, which is exactly why reaching for it would be the wrong
 * move — a formatter that is nearly right is how two surfaces end up disagreeing
 * about what a timestamp is.
 *
 * Seconds precision: the hub's `ts` carries fractional seconds on some rows
 * (`2026-09-22T09:07:33.67515Z`) and the owner's example does not.
 */
export function formatIsoTs(ts) {
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return String(ts || '')
  return d.toISOString().replace(/\.\d+Z$/, 'Z')
}

/** UTC wall clock `yyyy-mm-dd HH:MM:SS` of a v:1 `ts` (RFC3339 Z). */
export function formatAbsTs(ts) {
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return String(ts || '')
  const iso = d.toISOString()
  return iso.slice(0, 10) + ' ' + iso.slice(11, 19)
}

/**
 * Age in the coarsest units that still fit. Under one minute: `7s` / `0s`.
 * From one minute on, seconds drop (`1m`, `2h 3m`) so a ticking clock does
 * not keep a seconds field once minutes have started.
 */
export function formatElapsed(sec) {
  const n = Math.max(0, Math.floor(Number(sec) || 0))
  const h = Math.floor(n / 3600)
  const m = Math.floor((n % 3600) / 60)
  const s = n % 60
  const parts = []
  if (h) parts.push(h + 'h')
  if (m) parts.push(m + 'm')
  if (!h && !m) parts.push(s + 's')
  return parts.join(' ')
}

/**
 * Thread-pane clock: absolute UTC time, the word `sent`, then elapsed age
 * (`7s` / `1m` / `2h 3m`) from `originMs` (thread open, ticking).
 * A reply after open shows `sent 0s` until origin catches up.
 */
export function formatThreadTs(ts, originMs) {
  const abs = formatAbsTs(ts)
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return abs
  const origin = Number(originMs)
  if (!Number.isFinite(origin)) return abs
  const sec = Math.max(0, Math.floor((origin - d.getTime()) / 1000))
  return abs + ' sent ' + formatElapsed(sec)
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

/**
 * The card for our own live send, built from the hub ack before the echo frame.
 *
 * It carries the ack's `delivery` and `to_box` through (CLE-3435). The hub
 * already decides both in `onSend` and puts them on the ack - `sent` means it
 * handed the message to the recipient's box, `queued` that the box is offline
 * and it is being held - and until now the client threw them away. That is the
 * only evidence a human has that their message ARRIVED, and it is available
 * ~83 ms after they press send, against a reply that takes ~14 s because it
 * contains a model turn. A reader that does not understand a value must show
 * nothing rather than guess, so an absent `delivery` stays absent.
 */
export function rowFromAck(ack, frame, { from = '', channel = null } = {}) {
  const a = ack || {}
  const f = frame || {}
  return {
    ...(a.delivery ? { delivery: String(a.delivery) } : {}),
    ...(a.to_box ? { to_box: String(a.to_box) } : {}),
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
    parent_task_id: (typeof f.parent_task_id === 'string' && f.parent_task_id) ? f.parent_task_id : null,
  }
}

/**
 * One card per thread (task_id), carrying the thread's LAST activity
 * (CLE-3425). The card itself stays the thread's oldest message — that is the
 * root the channel lists — but `last_ts` is the newest moment of any message of
 * that task, so a reply inside an old thread bumps the card. A hub thread row
 * (thread_row) already carries `last_ts` and its own `count`; a flat page gets
 * both computed here.
 */
export function threadCards(messages) {
  const out = []
  const at = new Map()
  for (const m of messages || []) {
    const id = m && m.task_id
    if (!id) {
      out.push(m)
      continue
    }
    const i = at.get(id)
    if (i === undefined) {
      at.set(id, out.length)
      out.push({ ...m, last_ts: activityOf(m) })
      continue
    }
    const card = out[i]
    const ts = activityOf(m)
    out[i] = {
      ...card,
      last_ts: ts > activityOf(card) ? ts : activityOf(card),
      count: card.thread_row ? card.count : (Number(card.count) || 0) + 1,
    }
  }
  return out
}

/** Earliest message by `ts` (tie: msg_id). Pane 2's starter, not array order. */
function earlierByTs(a, b) {
  const c = String(a.ts || '').localeCompare(String(b.ts || ''))
  if (c !== 0) return c < 0 ? a : b
  return String(a.msg_id || '').localeCompare(String(b.msg_id || '')) <= 0 ? a : b
}

/**
 * Channel / DM pane 2: one card per task_id. The card is the earliest message
 * by ts with no parent_task_id. A later message with that task_id is a reply
 * even with no parent_task_id. A message with parent_task_id is a reply of
 * that parent and is never its own card. Replies only move last_ts and count,
 * so the card's author and body stay the starter's.
 */
function threadStarterCards(messages) {
  const list = []
  for (const m of messages || []) if (m) list.push(m)
  const starterOf = new Map()
  for (const m of list) {
    if (m.parent_task_id || !m.task_id) continue
    const prev = starterOf.get(m.task_id)
    starterOf.set(m.task_id, prev ? earlierByTs(prev, m) : m)
  }
  const cards = new Map()
  for (const [id, m] of starterOf) cards.set(id, { ...m, last_ts: activityOf(m) })
  for (const m of list) {
    const id = String(m.parent_task_id || m.task_id || '')
    const card = id && cards.get(id)
    if (!card) continue
    if (!m.parent_task_id && card.msg_id === m.msg_id) continue
    const ts = activityOf(m)
    cards.set(id, {
      ...card,
      last_ts: ts > activityOf(card) ? ts : activityOf(card),
      count: card.thread_row ? card.count : (Number(card.count) || 0) + 1,
    })
  }
  const out = []
  const seen = new Set()
  for (const m of list) {
    if (m.parent_task_id || !m.task_id || seen.has(m.task_id)) continue
    const card = cards.get(m.task_id)
    if (!card) continue
    seen.add(m.task_id)
    out.push(card)
  }
  for (const m of list) {
    if (!m.task_id && !m.parent_task_id) out.push(m)
  }
  return out
}

/**
 * 013 on /channel, /dm and #lobby (X3): newest ACTIVITY first (a reply bumps
 * its starter), the Omnibox `/search` filter, then the first `visible` rows.
 * Storage order is untouched.
 *
 * Pane 2 lists only the message that started the thread. A later message on
 * the same task_id is a reply even when it has no parent_task_id — that is
 * how the hub stores a follow-up in #lobby, which is one shared task. A
 * message whose parent_task_id names another task is that task's reply and
 * is never its own card. The card keeps the starter's author and body; the
 * reply stays in pane 3.
 *
 * `lobby` is accepted and ignored: #lobby uses this same rule.
 */
export function channelView(messages, { search = '', visible = 50 } = {}) {
  const rows = threadStarterCards(messages).filter((m) => matchesSearch(m, search))
  return windowed(newestActivityFirst(rows), visible)
}

/**
 * CLE-3425 — the sidebar channel list, newest first. A channel ranks by the
 * newest of: a live message just pushed for it (`liveAt`, so the order moves
 * with no refetch), the hub's `last_ts`, and its `created_at` (so a channel
 * created seconds ago tops the list although nobody has posted in it yet).
 * Channels nothing is known about keep a stable a-z tail.
 */
export function channelActivity(row, liveAt = {}) {
  const c = row || {}
  const id = String(c.channel_id || c.channel || '')
  return [String(liveAt[id] || ''), String(c.last_ts || ''), String(c.created_at || '')]
    .reduce((a, b) => (b > a ? b : a), '')
}

/**
 * CLE-3446 — the RIGHT-hand party of a row, in the owner's settled format:
 *
 *   [identicon] HUM-17@box-wui   ->  [robot] CLE-3444@box-desk   note   <iso>
 *   [robot] CLE-3444@box-desk    ->  [identicon] HUM-17@box-wui  note   <iso>
 *
 * The arrow flips per row because BOTH ends are read from that message, which
 * is the whole point: before this, a row carried the thread root's identity
 * and every row of a two-party conversation showed the same face.
 *
 * A BROADCAST has no right-hand party and shows the sender alone. There are
 * TWO sentinels for "everyone" and both must be excluded, which is the kind of
 * thing that is only obvious once you have seen the other one render:
 *
 *  - `ALL-0`     the hub's, on every row that comes off the wire
 *                (`spool-client.mjs` live send, `live-ws.mjs` §4 default)
 *  - `@channel`  the client's, from `parseMention` (line 28), `rowFromAck`
 *                (line 343) and the optimistic row in `stores/channel.ts:320`,
 *                and never sent — `spool-client.mjs:317` strips it before the
 *                frame goes out.
 *
 * Excluding only `ALL-0` would put an arrow, an id and a generated ROBOT avatar
 * for a participant called "@channel" beside every ordinary channel message the
 * viewer sends. Returns null for both, and for a row that addresses nobody.
 */
export function recipientOf(msg) {
  const m = msg || {}
  const id = String(m.to || '')
  if (!id || id === 'ALL-0' || id === '@channel') return null
  return { id, box: String(m.to_box || '') }
}

export function orderChannels(rows, liveAt = {}) {
  return (rows || []).slice().sort((a, b) => {
    const c = channelActivity(b, liveAt).localeCompare(channelActivity(a, liveAt))
    return c !== 0 ? c : String(a.channel_id || '').localeCompare(String(b.channel_id || ''))
  })
}

/**
 * CLE-3425 — the sidebar DM list, newest first: peers ranked by the last DM
 * either way (`lastAt` keyed by "<id>@<box>"). Peers with no DM yet keep the
 * old tail — online first, then a-z — so the list is stable for a fresh tenant.
 */
export function orderPeers(rows, lastAt = {}) {
  const at = (p) => String((lastAt || {})[String((p && p.label) || '')] || '')
  return (rows || []).slice().sort((a, b) => {
    const c = at(b).localeCompare(at(a))
    if (c !== 0) return c
    if (Boolean(a.online) !== Boolean(b.online)) return a.online ? -1 : 1
    return String(a.label || '').localeCompare(String(b.label || ''))
  })
}

/**
 * CLE-3425 — last DM moment per peer label from view-v1 §4.3 DM thread rows
 * (`?dm=true`), for orderPeers. `self` (our own label) is never a peer.
 */
export function dmActivity(threads, self = '') {
  const out = {}
  for (const t of threads || []) {
    const at = String((t && (t.last_ts || t.first_ts)) || '')
    for (const p of (t && t.participants) || []) {
      const label = String(p || '')
      if (!label || label === self) continue
      if (at > String(out[label] || '')) out[label] = at
    }
  }
  return out
}

/**
 * CLE-3425 — the DM peer of one message, as the sidebar labels peers
 * ("<id>@<box>"): the end that is not us. `self` is our v:1 id (live.identity);
 * a broadcast (ALL-0) and a message with no other end give ''.
 */
export function dmPeerOf(msg, self = '') {
  const m = msg || {}
  const me = String(self || '')
  for (const [id, box] of [[m.from, m.from_box], [m.to, m.to_box]]) {
    const i = String(id || '')
    if (!i || i === me || /^ALL-0$/.test(i)) continue
    return box ? `${i}@${box}` : i
  }
  return ''
}

/**
 * CLE-3425 — fold one live frame into the per-channel / per-peer "last activity"
 * maps the sidebar orders by. Returns the new maps (the same objects when
 * nothing moved, so a store can skip the write).
 */
export function noteActivity({ channels = {}, peers = {} }, msg, self = '') {
  const m = msg || {}
  const at = String(m.received_at || m.ts || '')
  if (!at) return { channels, peers }
  const ch = String(m.channel || '').replace(/^#/, '').toLowerCase()
  if (ch) {
    if (at <= String(channels[ch] || '')) return { channels, peers }
    return { channels: { ...channels, [ch]: at }, peers }
  }
  const label = dmPeerOf(m, self)
  if (!label || at <= String(peers[label] || '')) return { channels, peers }
  return { channels, peers: { ...peers, [label]: at } }
}

/**
 * CLE-3425 — a `channel` frame (a channel created anywhere in the tenant) into
 * the sidebar rows: a new row is added, a known one keeps what the hub told us.
 * orderChannels puts it on top through its created_at.
 */
export function addChannelRow(rows, frame) {
  const f = frame || {}
  const id = String(f.channel || '')
  if (!id) return rows || []
  const list = rows || []
  if (list.some((c) => String(c.channel_id || '') === id)) return list
  return [...list, {
    channel_id: id,
    name: String(f.name || id),
    description: String(f.description || ''),
    created_by: String(f.created_by || ''),
    created_at: String(f.created_at || ''),
    default: false,
    count: 0,
    unread: 0,
    last_ts: null,
  }]
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
