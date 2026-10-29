/**
 * The EAGER core of utils/channel-feed.mjs: the feed, unread and catch-up
 * helpers the channel and notification stores, the spool client and the
 * live follow run before first paint. The initial JS chunk is at its 027
 * budget (ci_initial_gzip_kb 155), so the helpers only lazy pages render
 * with (time and size formats, topic cards, recipients, retention labels)
 * stay in channel-feed.mjs. Lazy code and the tests import channel-feed.mjs,
 * which re-exports this file.
 */

import { stripBidiControls } from './bidi.mjs'
import { BOX_ID_SRC, PARTICIPANT_ID_SRC } from './agent-id.mjs'
import { activityOf, matchesSearch, newestActivityFirst, windowed } from './feed.mjs'
import { isUnread } from './read-cursor.mjs'
import { isViewersOwn } from './typed-by.mjs'

export function topLevel(messages) {
  return messages
    .filter((m) => !m.parent_task_id)
    .slice()
    .sort((a, b) => String(a.ts).localeCompare(String(b.ts)))
}

/* a leading @<ID>[@<box>]: either id form (spec 061), its box (spec 058) */
const LEAD_MENTION_RE = new RegExp(String.raw`^@(${PARTICIPANT_ID_SRC})(?:@(${BOX_ID_SRC}))?\b\s*([\s\S]*)$`)

export function parseMention(text) {
  const raw = String(text || '')
  const m = raw.match(LEAD_MENTION_RE)
  /* A leading `@ID` FOLLOWED BY TEXT dispatches a task to that id; the text is
     the body. A BARE mention (nothing after it) is not a task - it is a message
     that mentions someone - so it stays a channel note with the mention itself
     as the body. Stripping a bare `@CLE-00` to an empty body was the whole of
     "a message that starts with @ cannot be sent" (owner, prd t1 e09a72f7): the
     empty-send guard then refused the very row the person meant to post. The
     mention is still resolved either way - mentionPoke scans the raw text and
     DMs the addressee - so only the body changes, never the poke. */
  if (!m || !m[3].trim()) return { to: '@channel', kind: 'note', body: raw }
  /* specs/058 (CLE-77932): `@CLE-001@sat` keeps its box. CLE-001..003 run on
     every box, so the frame must carry to_box or the hub refuses the bare id
     as ambiguous_to_box. A bare `@CLE-07` has no toBox key at all. */
  return m[2] ? { to: m[1], toBox: m[2], kind: 'task', body: m[3] } : { to: m[1], kind: 'task', body: m[3] }
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

/** Hub channel slug (channels-v1 §5.1: ^[a-z0-9][a-z0-9-]{0,63}$). */
export function channelSlug(name) {
  return String(name || '')
    .toLowerCase()
    .replace(/^#/, '')
    .replace(/[^a-z0-9-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 64)
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
    /* 014 §3.2: a reply to a retired seat went to the whole topic */
    to: a.fallback === 'topic' ? '@channel' : (f.to || '@channel'),
    kind: f.kind || 'note',
    body: String(f.body || ''),
    files: f.files || [],
    channel,
    parent_task_id: (typeof f.parent_task_id === 'string' && f.parent_task_id) ? f.parent_task_id : null,
    ...(f.is_parent === 0 || f.is_parent === 1 ? { is_parent: f.is_parent } : {}),
  }
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

export function orderChannels(rows, liveAt = {}) {
  return (rows || []).slice().sort((a, b) => {
    const c = channelActivity(b, liveAt).localeCompare(channelActivity(a, liveAt))
    return c !== 0 ? c : String(a.channel_id || '').localeCompare(String(b.channel_id || ''))
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
    if (addHubDmCounts(out, t, 'unread')) continue
    const msgs = t && t.inline && Array.isArray(t.inline.messages) ? t.inline.messages : []
    for (const m of msgs) {
      if (!m || m.channel || !m.from) continue
      /* CLE-77889: our own line - or one we typed at the agent's terminal - is never new */
      if (isViewersOwn(m, me)) continue
      const peer = dmPeerOf(m, me)
      if (!peer) continue
      const key = `dm:${peer}`
      if (isUnread(m, cs[key])) out[key] = (out[key] || 0) + 1
    }
  }
  return out
}

/**
 * CLE-77845 (owner, topic 5dc55d94): the per-peer DM TOTAL beside the unread
 * count, so the rail badge reads "<new>/<total>" as a topic card does. From the
 * same `?dm=true` rows unreadFromDms reads: a topic whose inline page holds all
 * of it counts each line under its own peer (dmPeerOf); a topic held only in
 * part adds the hub's row count to each end that is not us. Own lines count -
 * a total is every message of the DM, not only the incoming ones.
 *
 * @param {Array<{ count?: number, participants?: string[], inline?: { messages?: any[] } }>} topics
 * @param {string} self our own v:1 id (live.identity)
 * @returns {Record<string, number>} `dm:<peer>` → total messages
 */
export function dmTotalsFromDms(topics, self = '') {
  const me = String(self || '')
  const out = {}
  const add = (peer, n) => {
    if (peer) out[`dm:${peer}`] = (out[`dm:${peer}`] || 0) + n
  }
  for (const t of topics || []) {
    if (!t || addHubDmCounts(out, t, 'total')) continue
    const msgs = t.inline && Array.isArray(t.inline.messages) ? t.inline.messages : null
    const count = Number(t.count) || 0
    if (msgs && msgs.length >= count) {
      for (const m of msgs) if (m && !m.channel) add(dmPeerOf(m, me), 1)
      continue
    }
    for (const p of t.participants || []) {
      const label = String(p || '')
      const id = label.split('@')[0]
      if (!id || id === me || /^ALL-0$/.test(id)) continue
      add(label, count)
    }
  }
  return out
}

/**
 * DB payload cut 1 (audit 2026-10-02): a `?dm=true&dm_counts=true` row carries
 * the hub's own per-peer counts, `dm: { unread, total }` keyed "<id>@<box>",
 * made by the rules above against the dm_read= cursors we sent
 * (dmReadParams), so the seed needs no inline page. Adds the row's `which`
 * map into out under `dm:<peer>`; false = the row has none (an older hub).
 */
function addHubDmCounts(out, t, which) {
  const m = t && t.dm && t.dm[which]
  if (!m || typeof m !== 'object') return false
  for (const [peer, n] of Object.entries(m)) {
    if (peer && Number.isFinite(n)) out[`dm:${peer}`] = (out[`dm:${peer}`] || 0) + n
  }
  return true
}

/**
 * the `dm_read=<id>@<box>~<ts>~<msg-id>` marks of our DM cursors, for the
 * hub's dm_counts (one per `dm:` cursor that has a time).
 */
export function dmReadParams(cursors) {
  return Object.entries(cursors || {})
    .filter(([k, c]) => k.startsWith('dm:') && k.length > 3 && c && c.ts)
    .map(([k, c]) => `${k.slice(3)}~${c.ts}~${c.id || ''}`)
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

/** R2-2: the most held reaction counts a catch-up sends (hub view_delta.go deltaMaxHeld). */
export const CATCH_UP_RX_MAX = 200

/** Hub receive time of a row in ms; 0 when it has none. */
function receivedMs(m) {
  return Date.parse(String((m && (m.received_at || m.ts)) || '')) || 0
}

/** Reaction rows (actor x emoji) on m, as the hub counts them. */
function reactionRows(m) {
  const list = Array.isArray(m && m.reactions) ? m.reactions : []
  return list.reduce((n, r) => n + (Array.isArray(r && r.actors) ? r.actors.length : 0), 0)
}

/** The time inside a view cursor (base64url of `<RFC 3339>|<id>`) in ms; 0 when it is not one. */
export function cursorTime(cursor) {
  try {
    const raw = atob(String(cursor || '').replace(/-/g, '+').replace(/_/g, '/'))
    return Date.parse(raw.split('|')[0]) || 0
  } catch {
    return 0
  }
}

/**
 * R2-2 reconnect delta: what a catch-up tells the hub. `since` is the cursor
 * of the newest row held (hub receive time) - or the `sync` cursor the last
 * catch-up answered, when that is later, so a change already caught up is
 * not sent again - and `rx` is `<msg_id>~<n>` for every held row with
 * reactions, so a reaction REMOVED in the gap - which leaves nothing behind
 * on the hub - is found by its count. `sinceAt` stays the newest row's time
 * (mergeCatchUp's floor). null = read the full page: no row with a cursor is
 * held, or more reacted rows than the hub takes.
 */
export function catchUpQuery(rows, sync = '') {
  let best = null
  const rx = []
  for (const m of rows || []) {
    if (!m || m.pending || m.topic_row) continue
    const at = receivedMs(m)
    if (m.cursor && at && (!best || at > best.at)) best = { at, since: String(m.cursor), sinceAt: String(m.received_at || m.ts) }
    const n = reactionRows(m)
    if (n > 0 && m.msg_id) rx.push(`${m.msg_id}~${n}`)
  }
  if (!best || rx.length > CATCH_UP_RX_MAX) return null
  const since = cursorTime(sync) > best.at ? String(sync) : best.since
  return { since, sinceAt: best.sinceAt, rx }
}

/**
 * R2-2: merge a catch-up answer into the held rows. Unlike mergePage, a held
 * row is REPLACED by its fresh copy, in place and never re-sorted, so an
 * edit, kind change, reaction or move made while the socket was down shows -
 * on the delta and on the full page alike (mergePage kept the stale row).
 * A delta (`delta: true`) also drops every row of a gone task and each gone
 * msg (archived, moved out), and adds a row the feed did not hold only when
 * its topic is held or it arrived after `sinceAt`: a changed OLD topic the
 * feed never loaded does not appear in the middle of its history.
 */
export function mergeCatchUp(rows, incoming, { delta = false, goneTasks = [], goneMsgs = [], sinceAt = '' } = {}) {
  const goneT = new Set((goneTasks || []).map(String))
  const goneM = new Set((goneMsgs || []).map(String))
  const list = (rows || []).filter((m) => !m || !(goneM.has(String(m.msg_id || '')) || goneT.has(String(m.task_id || ''))))
  const at = new Map(list.map((m, i) => [m && m.msg_id, i]))
  const heldTasks = new Set(list.map((m) => String((m && m.task_id) || '')).filter(Boolean))
  const floor = Date.parse(String(sinceAt || '')) || 0
  for (const m of incoming || []) {
    if (!m || !m.msg_id) continue
    const i = at.get(m.msg_id)
    if (i !== undefined) {
      const held = list[i]
      list[i] = held.topic_row || held.pending ? m : { ...held, ...m }
      continue
    }
    if (delta && !heldTasks.has(String(m.task_id || '')) && !(receivedMs(m) > floor)) continue
    at.set(m.msg_id, list.length)
    list.push(m)
  }
  return list
}
