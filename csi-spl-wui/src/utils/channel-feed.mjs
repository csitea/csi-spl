/**
 * Pure feed helpers. Node tests import this file; Vue stores wrap it. What
 * the stores need before first paint is the eager channel-feed-core.mjs,
 * re-exported here.
 */

import { isoClock, isoDate, isoDateTime, isoDateTimeSec } from './date-iso.mjs'
import { activityOf, mergeById } from './feed.mjs'
import { displayName, peopleLabels, personLabel, topicRepliesIn, topicReplyIndex } from './channel-feed-core.mjs'

export { CATCH_UP_RX_MAX, addChannelRow, applyChannelFrame, belongsTo, catchUpQuery, channelActivity, channelFollow, channelSlug, channelView, cursorTime, displayName, dmActivity, dmFollow, dmPeerOf, dmReadParams, dmTotalsFromDms, dropFromTotals, feedRow, followPlan, mergeCatchUp, mergeLive, mergeTopicTotals, namedRuns, namedText, noteActivity, orderChannels, parseMention, peopleLabels, personLabel, rootsByTask, rowFromAck, topLevel, topicRepliesIn, topicReplyIndex, unreadFromDms } from './channel-feed-core.mjs'

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
 * HH:MM of a message timestamp on the viewer's own clock (CLE-77908: it was
 * UTC, three hours early in Finland). The same 24-hour digits in every UI
 * locale. Channel / list cards keep this form.
 */
export function formatTs(ts, _locale) {
  /* 24-hour HH:MM in every UI locale. A locale used to rewrite 14:05 as 14.05. */
  return isoClock(ts) || String(ts || '')
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
  return isoDateTime(ts) || String(ts || '')
}

/** The viewer's own wall clock of `d`: `{ day: 'yyyy-mm-dd', hm: 'HH:MM' }`. */
function wallClock(d) {
  return { day: isoDate(d), hm: isoClock(d) }
}

/**
 * SPL-1007 (owner, 2026-09-27, topic 70c82b54, on mobile): a message from
 * today shows only its time - `13:43`; another day this year `09-26 23:59`,
 * another year `2025-12-31 23:59` (SPL-1000).
 *
 * (owner, prd t1 topic 95adf832, 2026-09-28 00:3x EEST): "today"
 * is the VIEWER's local calendar day, on every phone surface. The first cut
 * read "today" in the frame the text was printed in, and the topic pane's
 * clock printed UTC then (local since CLE-77908), so between local midnight and UTC midnight a viewer east
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

/** The viewer's local wall clock `yyyy-mm-dd HH:MM:SS` of a v:1 `ts` (RFC3339 Z).
 *  CLE-77908 (owner, "off by 3hours"): this was UTC, so the topic pane's
 *  `... sent 7s` clock read three hours early in Finland. */
export function formatAbsTs(ts) {
  return isoDateTimeSec(ts) || String(ts || '')
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
 * Topic-pane clock: absolute local time, the word `sent`, then elapsed age
 * (`7s` / `1m` / `2h 3m`) from `originMs` (topic open, ticking).
 * A reply after open shows `sent 0s` until origin catches up.
 * SPL-2144: `sent(at, age)` words it in the UI language (MessageCard passes
 * t('feed.time_sent')); without it the line stays English.
 * @param {unknown} ts
 * @param {unknown} originMs
 * @param {(at: string, age: string) => string} [sent]
 */
export function formatTopicTs(ts, originMs, sent = (at, age) => at + ' sent ' + age) {
  const abs = formatAbsTs(ts)
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return abs
  const origin = Number(originMs)
  if (!Number.isFinite(origin)) return abs
  const sec = Math.max(0, Math.floor((origin - d.getTime()) / 1000))
  return sent(abs, formatElapsed(sec))
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
 * dc6d5e3f: none for a DM-view pointer either (utils/dm-pointer.mjs) - it is
 * a line between the reader and the DM's agent, which the page already
 * names, and the "-> recipient" wrapped its header at 390 px.
 */
export function headerRecipientOf(msg) {
  const m = msg || {}
  if (m.pointer || !String(m.channel || '').trim().replace(/^#/, '')) return null
  return recipientOf(m)
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
