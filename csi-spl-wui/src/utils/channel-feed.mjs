/** Pure feed helpers. Node tests import this file; Vue stores wrap it. */

import { bodyToHtml, stripBidiControls } from './code-blocks.mjs'
import { activityOf, matchesSearch, mergeById, newestActivityFirst, newestFirst, windowed } from './feed.mjs'
import { isUnread } from './read-cursor.mjs'

export function topLevel(messages) {
  return messages
    .filter((m) => !m.parent_task_id)
    .slice()
    .sort((a, b) => String(a.ts).localeCompare(String(b.ts)))
}

export function topicOf(messages, parentTaskId) {
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

/**
 * What a person is called on screen: the display name they chose, else the
 * id (displayName). Only a human on the browser box (or with no box) has one;
 * an agent is always its id.
 *
 * @param {string} id
 * @param {string | undefined} box
 * @param {Record<string, string> | null | undefined} names humanNamesFromView
 */
export function personLabel(id, box, names) {
  // bidi controls dropped: a chosen name must not reorder the row around it
  const n = names && typeof names === 'object' && Object.prototype.hasOwnProperty.call(names, id) ? stripBidiControls(names[id] || '').trim() : ''
  if (n && /^HUM-/.test(String(id || '')) && (!box || box === 'box-wui')) return n
  return displayName(id, box)
}

/**
 * An @mention as shown in a message (owner, 2026-09-26: humans by their
 * display name everywhere). `@HUM-10` / `@HUM-10@box-wui` of a member who
 * chose a name reads `@<name>`, the tag itself kept for the hover; an agent
 * or a nameless member keeps the tag as typed.
 *
 * @param {string} text the mention as parsed, with its leading '@'
 * @param {Record<string, string> | null | undefined} names
 * @returns {{ text: string, title: string }}
 */
export function mentionDisplay(text, names) {
  const raw = String(text || '')
  const tag = raw.replace(/^@/, '')
  const at = tag.indexOf('@')
  const id = at >= 0 ? tag.slice(0, at) : tag
  const box = at >= 0 ? tag.slice(at + 1) : undefined
  const label = personLabel(id, box, names)
  if (!/^HUM-/.test(id) || label === displayName(id, box)) return { text: raw, title: '' }
  return { text: '@' + label, title: raw }
}

/* SPL-1009: a member id written as plain text ("HUM-10 needs you in ...", an
   agent's "asked by HUM-10") - not part of a longer token or an @tag. */
const BARE_MEMBER_RE = /(^|[^\w@-])(HUM-\d+)(?![\w@-])/g

/**
 * Plain message text as runs: each member id of a member who chose a name
 * reads that name, the id kept as its title. An agent, a nameless member and
 * an unknown id stay as written. `[{ text }]` when nothing changes.
 *
 * @param {string} text
 * @param {Record<string, string> | null | undefined} names
 * @returns {{ text: string, title?: string }[]}
 */
export function namedRuns(text, names) {
  const s = String(text || '')
  const out = []
  let last = 0
  for (const m of s.matchAll(BARE_MEMBER_RE)) {
    const id = m[2]
    const label = personLabel(id, undefined, names)
    if (label === id) continue
    const at = m.index + m[1].length
    if (at > last) out.push({ text: s.slice(last, at) })
    out.push({ text: label, title: id })
    last = at + id.length
  }
  if (last < s.length || !out.length) out.push({ text: s.slice(last) })
  return out
}

/**
 * A text for a place that shows plain strings (a browser notification, a
 * search snippet): `@HUM-n` and bare `HUM-n` of a named member read the name.
 *
 * @param {string} text
 * @param {Record<string, string> | null | undefined} names
 */
export function namedText(text, names) {
  const s = String(text || '').replace(/(^|[^\w@-])@(HUM-\d+)(?:@box-wui)?(?![\w@-])/g, (m, pre, id) => {
    const label = personLabel(id, undefined, names)
    return label === id ? m : `${pre}@${label}`
  })
  return namedRuns(s, names).map((r) => r.text).join('')
}

/**
 * A list of peers ("HUM-10", "CLE-7@box-a") as people read it: each human by
 * their chosen name, everyone else unchanged, joined with ', '.
 *
 * @param {readonly string[] | null | undefined} peers
 * @param {Record<string, string> | null | undefined} names
 */
export function peopleLabels(peers, names) {
  return (Array.isArray(peers) ? peers : []).map((p) => {
    const s = String(p || '')
    const at = s.indexOf('@')
    return at > 0 ? personLabel(s.slice(0, at), s.slice(at + 1), names) : personLabel(s, undefined, names)
  }).join(', ')
}

/**
 * Visible label. A human is the name they chose, or the bare HUM id when
 * they have not chosen one. An agent stays id@box.
 */
export function shownPerson(id, box, names) {
  const who = String(id || '')
  if (/^HUM-/.test(who)) return personLabel(who, undefined, names)
  return personLabel(who, box, names)
}

/**
 * Hover and tap text. A named human is "Name · HUM-n": the whole name when
 * the row is too narrow, and the id so two people who chose the same name
 * stay distinguishable. A nameless human is the bare id. An agent is id@box.
 */
export function personTitle(id, box, names) {
  const who = String(id || '')
  const name = shownPerson(id, box, names)
  if (!/^HUM-/.test(who)) return name
  if (!name || name === who) return who
  return `${name} · ${who}`
}

/**
 * A comma-separated peer line (a topic with no subject). Humans become their
 * names; the title keeps those names and the ids. Anything that is not a
 * peer list is returned unchanged.
 */
export function namedLine(line, names) {
  const raw = String(line || '')
  const parts = raw.split(',').map((s) => s.trim()).filter(Boolean)
  if (!parts.length) return { text: raw, title: raw }
  const text = peopleLabels(parts, names)
  if (!text || text === parts.join(', ')) return { text: raw, title: raw }
  return { text, title: `${text} · ${raw}` }
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
/* one Intl.NumberFormat per locale + digits: building one costs far more
   than formatting with it, and every file card formatted its size (CLE-35075) */
const byteFormats = new Map()
function byteFormat(locale, digits) {
  const key = locale + '|' + digits
  let f = byteFormats.get(key)
  if (!f) {
    f = new Intl.NumberFormat(locale, { minimumFractionDigits: digits, maximumFractionDigits: digits })
    byteFormats.set(key, f)
  }
  return f
}

export function formatBytes(n, locale) {
  const v = Number(n) || 0
  const fmt = (x, digits) => {
    if (!locale) return digits ? x.toFixed(digits) : String(x)
    try {
      return byteFormat(locale, digits).format(x)
    } catch {
      return digits ? x.toFixed(digits) : String(x)
    }
  }
  if (v < 1024) return `${fmt(v, 0)} B`
  if (v < 1024 * 1024) return `${fmt(v / 1024, 1)} KiB`
  return `${fmt(v / (1024 * 1024), 1)} MiB`
}

/**
 * HH:MM (UTC) of a message timestamp. The same 24-hour digits in every UI
 * locale. Channel / list cards keep this form.
 */
export function formatTs(ts, _locale) {
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return String(ts || '')
  /* 24-hour UTC HH:MM in every UI locale. A locale used to rewrite 14:05 as 14.05. */
  return d.toISOString().slice(11, 16)
}

/**
 * the owner's settled row format wants a REAL ISO 8601 stamp, with
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

/** Message-list clock: local `yyyy-mm-dd HH:MM`. No `T`, no seconds, no `Z`.
 *  Dropping the zone makes a UTC clock read as the wrong hour, so this is
 *  the reader's wall time. The full ISO UTC value stays on the hover. */
export function formatMsgListTs(ts) {
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return String(ts || '')
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
}

/** The viewer's own wall clock of `d`: `{ day: 'yyyy-mm-dd', hm: 'HH:MM' }`. */
function wallClock(d) {
  const p = (n) => String(n).padStart(2, '0')
  return { day: `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`, hm: `${p(d.getHours())}:${p(d.getMinutes())}` }
}

/**
 * SPL-1007 (owner, 2026-09-27, topic 70c82b54, on mobile): a message from
 * today shows only its time - `13:43`; another day this year `09-26 23:59`,
 * another year `2025-12-31 23:59` (SPL-1000).
 *
 * (owner, prd t1 topic 95adf832, 2026-09-28 00:3x EEST): "today"
 * is the VIEWER's local calendar day, on every phone surface. The first cut
 * read "today" in the frame the text was printed in, and the topic pane's
 * clock prints UTC, so between local midnight and UTC midnight a viewer east
 * of Greenwich read a UTC hour, and west of it a date on today's lines. A
 * phone now prints the viewer's own wall clock from `ts` itself, and "only
 * the hours": the topic pane's ` sent 7s` tail and its seconds are dropped
 * too, so the header keeps to one line. `text` (what formatMsgListTs /
 * formatTopicTs printed) passes through when it is not a time. The hover
 * keeps the whole value.
 * @param {string} text
 * @param {unknown} ts
 * @param {number} [nowMs]
 */
export function phoneCardTime(text, ts, nowMs = Date.now()) {
  const s = String(text || '')
  const d = new Date(/** @type {any} */ (ts))
  if (Number.isNaN(d.getTime()) || !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(s)) return s
  const at = wallClock(d)
  const now = wallClock(new Date(nowMs))
  if (at.day === now.day) return at.hm
  return (at.day.slice(0, 4) === now.day.slice(0, 4) ? at.day.slice(5) : at.day) + ' ' + at.hm
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
 * Topic-pane clock: absolute UTC time, the word `sent`, then elapsed age
 * (`7s` / `1m` / `2h 3m`) from `originMs` (topic open, ticking).
 * A reply after open shows `sent 0s` until origin catches up.
 */
export function formatTopicTs(ts, originMs) {
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
 * One feed row. A flat v:1 message passes through; a view-v1 §4.3 topic row
 * (live `/v1/view/topics?channel=` or `?dm=true&peer=`) becomes a root card
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
    topic_row: true,
  }
}

/**
 * One card per v:1 topic (task_id): live listMessages returns flat messages
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

/** Epoch ms of a message's hub time (received_at), else its own ts; NaN when neither parses. */
function msgAt(m) {
  return Date.parse(String((m && (m.received_at || m.ts)) || ''))
}

/**
 * Replies of one topic: child tasks (parent_task_id) plus in-topic messages
 * (same task_id). `total` is the hub's §4.3 row for the topic as last read
 * ({ count, last_ts }, listMessages `totals`): SPL-1008, the flat page keeps
 * only the newest lines of a 20-topic window, so an older topic holds its
 * opener and a few late replies, and counting what is held undercounts it
 * (prd t1: 2 shown, 6 stored). With a total the count is the hub's replies
 * plus the held lines that came after that read (live frames, own sends),
 * never below what is held.
 */
export function topicReplies(messages, taskId, total) {
  return topicRepliesIn(topicReplyIndex(messages), taskId, total)
}

/**
 * What topicReplies reads, for every topic at once: one pass over the held
 * rows. A channel page asks topicReplies for each card, and each call walked
 * every held row three times (a find and two filters), so a render of N
 * cards was O(N x rows); the store builds this once per `messages` and each
 * card reads it (CLE-35075). The first topic row per task wins, as find did.
 *
 * @param {any[]} messages
 */
export function topicReplyIndex(messages) {
  const rowOf = new Map()
  const children = new Map()
  const same = new Map()
  for (const m of messages || []) {
    if (m.topic_row && !rowOf.has(m.task_id)) rowOf.set(m.task_id, m)
    if (m.parent_task_id != null) children.set(m.parent_task_id, (children.get(m.parent_task_id) || 0) + 1)
    if (!m.topic_row) {
      const list = same.get(m.task_id)
      if (list) list.push(m)
      else same.set(m.task_id, [m])
    }
  }
  return { rowOf, children, same }
}

/**
 * topicReplies read from a topicReplyIndex.
 *
 * @param {ReturnType<typeof topicReplyIndex>} index
 * @param {string} taskId
 * @param {{ count?: number, last_ts?: string } | undefined} [total]
 */
export function topicRepliesIn(index, taskId, total) {
  if (!taskId) return 0
  const row = index.rowOf.get(taskId)
  const children = index.children.get(taskId) || 0
  if (row) return children + (Number(row.count) || 0)
  const same = index.same.get(taskId) || []
  const held = Math.max(0, same.length - 1)
  const n = Number(total && total.count) || 0
  if (n <= 0) return children + held
  const at = Date.parse(String(total.last_ts || ''))
  const later = Number.isFinite(at) ? same.filter((m) => m.pending || msgAt(m) > at).length : 0
  return children + Math.max(held, n - 1 + later)
}

/**
 * The hub's per-topic totals from a listMessages page (`page.totals`) merged
 * into those already held (SPL-1008). Per topic the read with the later
 * last_ts wins: a count and its last_ts are one snapshot, so either pair is
 * consistent for topicReplies; the later one leans on fewer held lines.
 *
 * @param {Record<string, { count: number, last_ts: string }> | null | undefined} held
 * @param {Record<string, { count: number, last_ts: string }> | null | undefined} incoming
 */
export function mergeTopicTotals(held, incoming) {
  const out = { ...(held || {}) }
  for (const [id, t] of Object.entries(incoming || {})) {
    if (!id || !t) continue
    const was = out[id]
    if (was && Date.parse(String(was.last_ts || '')) > Date.parse(String(t.last_ts || ''))) continue
    out[id] = { count: Number(t.count) || 0, last_ts: String(t.last_ts || '') }
  }
  return out
}

/**
 * A held message left the feed (deleted): the topic total that counted it
 * (the message is not newer than the total's read) loses one (SPL-1008).
 */
export function dropFromTotals(totals, msg) {
  const m = msg || {}
  const t = totals && m.task_id ? totals[m.task_id] : null
  if (!t || m.pending || msgAt(m) > Date.parse(String(t.last_ts || ''))) return totals
  return { ...totals, [m.task_id]: { ...t, count: Math.max(0, (Number(t.count) || 0) - 1) } }
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
 * msg_id → no-op, except that a confirmed row replaces a `pending` one. A reply to a topic row bumps its count; anything else
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
  const i = list.findIndex((r) => r.topic_row && r.task_id === root)
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
 * It carries the ack's `delivery` and `to_box` through. The hub
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
    ...(f.is_parent === 0 || f.is_parent === 1 ? { is_parent: f.is_parent } : {}),
  }
}

/**
 * One card per topic (task_id), carrying the topic's LAST activity
 * The card itself stays the topic's oldest message — that is the
 * root the channel lists — but `last_ts` is the newest moment of any message of
 * that task, so a reply inside an old topic bumps the card. A hub topic row
 * (topic_row) already carries `last_ts` and its own `count`; a flat page gets
 * both computed here.
 */
export function topicCards(messages) {
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
      count: card.topic_row ? card.count : (Number(card.count) || 0) + 1,
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

/** A reply written with the topics pane open. It stays in that pane. */
function hiddenFromMiddle(m) {
  return !!m && m.is_parent === 0
}

/**
 * Rows the right pane shows for one open topic. The topic read is the base.
 * A reply held by the channel feed (optimistic, or confirmed before the
 * topic read catches up) joins that list when it is still pending or when
 * is_parent is 0. Anything else in the channel feed stays in the middle.
 */
export function rowsForRightPane(topicRows, held, topicId) {
  const id = String(topicId || '')
  const extra = []
  for (const m of held || []) {
    if (!m || !id) continue
    if (m.task_id !== id && m.parent_task_id !== id) continue
    if (m.pending || m.is_parent === 0) extra.push(m)
  }
  return mergeById(topicRows || [], extra).rows
}

/**
 * Channel / DM pane 2: one card per task_id. The card is the earliest message
 * by ts with no parent_task_id. A later message with that task_id is a reply
 * even with no parent_task_id. A message with parent_task_id is a reply of
 * that parent and is never its own card. A message with is_parent 0 is a
 * reply from the open topics pane and is never a card. Replies only move
 * last_ts and count, so the card's author and body stay the starter's.
 */
function topicStarterCards(messages) {
  const list = []
  for (const m of messages || []) if (m) list.push(m)
  const starterOf = new Map()
  for (const m of list) {
    if (hiddenFromMiddle(m) || m.parent_task_id || !m.task_id) continue
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
      count: card.topic_row ? card.count : (Number(card.count) || 0) + 1,
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
    if (hiddenFromMiddle(m)) continue
    if (!m.task_id && !m.parent_task_id) out.push(m)
  }
  return out
}

/**
 * 013 on /channel, /dm and #lobby (X3): newest ACTIVITY first (a reply bumps
 * its starter), the Omnibox `/search` filter, then the first `visible` rows.
 * Storage order is untouched.
 *
 * Pane 2 lists only the message that started the topic. A later message on
 * the same task_id is a reply even when it has no parent_task_id — that is
 * how the hub stores a follow-up in #lobby, which is one shared task. A
 * message whose parent_task_id names another task is that task's reply and
 * is never its own card. The card keeps the starter's author and body; the
 * reply stays in pane 3.
 *
 * `lobby` is accepted and ignored: #lobby uses this same rule.
 */
export function channelView(messages, { search = '', visible = 50 } = {}) {
  const rows = topicStarterCards(messages).filter((m) => matchesSearch(m, search))
  return windowed(newestActivityFirst(rows), visible)
}

/**
 * the sidebar channel list, newest first. A channel ranks by the
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
 * the RIGHT-hand party of a row, in the owner's settled format:
 *
 *   [identicon] HUM-17@box-wui   ->  [robot] CLE-3444@box-desk   note   <iso>
 *   [robot] CLE-3444@box-desk    ->  [identicon] HUM-17@box-wui  note   <iso>
 *
 * The arrow flips per row because BOTH ends are read from that message, which
 * is the whole point: before this, a row carried the topic root's identity
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

/**
 * SPL-981 (owner, prd t1 topic 5cf46197): "in the direct messages only the
 * avatar of the sender should be visible ... remove the receiver of the msg
 * and the -> char". The card header's recipient: none for a direct message
 * (no channel), the recipientOf for a channel or topic message.
 */
export function headerRecipientOf(msg) {
  const m = msg || {}
  if (!String(m.channel || '').trim().replace(/^#/, '')) return null
  return recipientOf(m)
}

export function orderChannels(rows, liveAt = {}) {
  return (rows || []).slice().sort((a, b) => {
    const c = channelActivity(b, liveAt).localeCompare(channelActivity(a, liveAt))
    return c !== 0 ? c : String(a.channel_id || '').localeCompare(String(b.channel_id || ''))
  })
}

/**
 * The sidebar DM list (owner 2026-09-25, replacing CLE-3425's newest-first):
 * the peers that are ONLINE come first, whatever their history, so a
 * disconnected agent never sits above one you can reach. Inside each group,
 * the peers you have DMs with come next, newest last DM first (`lastAt` keyed
 * by "<id>@<box>"), then the ones with no DM yet, a-z.
 */
export function orderPeers(rows, lastAt = {}) {
  const at = (p) => String((lastAt || {})[String((p && p.label) || '')] || '')
  return (rows || []).slice().sort((a, b) => {
    if (Boolean(a.online) !== Boolean(b.online)) return a.online ? -1 : 1
    const c = at(b).localeCompare(at(a))
    if (c !== 0) return c
    return String(a.label || '').localeCompare(String(b.label || ''))
  })
}

/**
 * last DM moment per peer label from view-v1 §4.3 DM topic rows
 * (`?dm=true`), for orderPeers. `self` (our own label) is never a peer.
 */
export function dmActivity(topics, self = '') {
  const out = {}
  for (const t of topics || []) {
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
 * Per-peer DM unread from the reader's stored cursors and the inline messages
 * of the `?dm=true` topic rows (per_topic). This is the DM twin of the hub's
 * channel `unread` (channels-v1 §5.2, applied by unreadFromChannels): the hub
 * counts unread only for channels, so on a fresh load or after a reconnect a
 * DM that arrived while the tab was closed showed no badge, while a channel
 * message did. Only INCOMING lines (from !== self) newer than the peer's cursor
 * count - our own lines are read by definition, and a channel row is not a DM.
 * The key is `dm:<id>@<box>`, exactly as the sidebar labels a peer.
 *
 * @param {Array<{ inline?: { messages?: any[] } }>} topics ?dm=true rows with per_topic
 * @param {Record<string, { ts?: string, id?: string }>} cursors loadCursors()
 * @param {string} self our own v:1 id (live.identity)
 * @returns {Record<string, number>} `dm:<peer>` → unread count
 */
export function unreadFromDms(topics, cursors, self = '') {
  const cs = cursors || {}
  const me = String(self || '')
  const out = {}
  for (const t of topics || []) {
    const msgs = t && t.inline && Array.isArray(t.inline.messages) ? t.inline.messages : []
    for (const m of msgs) {
      if (!m || m.channel) continue
      const from = String(m.from || '')
      if (!from || from === me) continue
      const peer = dmPeerOf(m, me)
      if (!peer) continue
      const key = `dm:${peer}`
      if (isUnread(m, cs[key])) out[key] = (out[key] || 0) + 1
    }
  }
  return out
}

/**
 * the DM peer of one message, as the sidebar labels peers
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
 * fold one live frame into the per-channel / per-peer "last activity"
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
 * a `channel` frame (a channel created anywhere in the tenant) into
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
 * One sidebar frame applied to the channel rows (wui-live-ws v0.6):
 * `channel` adds a row, `channel_deleted` (SPL-72, channels-v1 §5.4) drops it.
 */
export function applyChannelFrame(rows, frame) {
  const f = frame || {}
  if (f.type !== 'channel_deleted') return addChannelRow(rows, f)
  const id = String(f.channel || '')
  const list = rows || []
  if (!id || !list.some((c) => String(c.channel_id || '') === id)) return list
  return list.filter((c) => String(c.channel_id || '') !== id)
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
 * Reconnect catch-up (FR-015): a fresh first page merged by msg_id — a topic
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
    } else if (list[i].topic_row || list[i].pending) {
      list[i] = m
    }
  }
  return list
}
