/**
 * Pure helpers for the 003 read-only viewer API (specs/003 contracts/view-v1.md).
 * Node tests import this file; the client and stores wrap it.
 *
 * Topic = task_id (v:1, 002). `channel` / `parent_task_id` are hub-envelope
 * fields (channels-v1 §0, §2), never v:1 fields: the normalisers below lift
 * them off the envelope / topic row onto the flat message (null when absent,
 * spec 005 FR-005). The mock tenant still carries parent_task_id, so mock
 * grouping folds a reply into its root task.
 */

import { normalizeReactions } from './emoji.mjs'

/** channels-v1 §2: absent, null and "" all mean absent → null. */
export function hubField(v) {
  return typeof v === 'string' && v ? v : null
}

const SUBJECT_MAX = 140
/** How much of the first message the topics list shows after "Topic:". */
export const TOPIC_TITLE_CHARS = 100

export function subjectOf(body) {
  const line = String(body || '').split('\n')[0].trim()
  return line.length > SUBJECT_MAX ? line.slice(0, SUBJECT_MAX) : line
}

/**
 * The title of an open topic: the pinned root when the click was one
 * message, otherwise the oldest row (the starter). Empty when there is
 * no text yet.
 */
export function topicTitleFromRows(rows, pinnedRoot) {
  const pinned = pinnedRoot && String(pinnedRoot.body || '').trim()
  if (pinned) return topicOpening(pinnedRoot.body)
  const list = Array.isArray(rows) ? rows : []
  let root = null
  for (const m of list) {
    if (!m) continue
    if (!root || String(m.ts || '') < String(root.ts || '')) root = m
  }
  return topicOpening(root && root.body)
}

/** First 100 characters of a topic's first message, whitespace collapsed.
 *  A longer message keeps those 100 and ends with "...". */
export function topicOpening(text) {
  const flat = String(text || '').replace(/\s+/g, ' ').trim()
  const chars = Array.from(flat)
  if (chars.length <= TOPIC_TITLE_CHARS) return flat
  return chars.slice(0, TOPIC_TITLE_CHARS).join('') + '...'
}

function label(id, box) {
  if (!id) return ''
  return box ? `${id}@${box}` : String(id)
}

/** Group flat v:1 messages into view-v1 §4.3 rows, newest activity first. */
export function topicsFromMessages(messages) {
  const by = new Map()
  const sorted = messages.slice().sort((a, b) => String(a.ts).localeCompare(String(b.ts)))
  for (const m of sorted) {
    const key = m.parent_task_id || m.task_id
    if (!key) continue
    let row = by.get(key)
    if (!row) {
      row = {
        task_id: key, first_ts: m.ts, last_ts: m.ts, count: 0,
        kinds: {}, participants: [], subject: subjectOf(m.body),
      }
      by.set(key, row)
    }
    row.count += 1
    row.last_ts = m.ts
    row.kinds[m.kind] = (row.kinds[m.kind] || 0) + 1
    for (const p of [label(m.from, m.from_box), label(m.to, m.to_box)]) {
      if (p && !p.startsWith('@') && !row.participants.includes(p)) row.participants.push(p)
    }
  }
  return [...by.values()].sort((a, b) => String(b.last_ts).localeCompare(String(a.last_ts)))
}

/** All messages of one topic, oldest first (mock side of view-v1 §4.4). */
export function topicMessages(messages, taskId) {
  return messages
    .filter((m) => (m.parent_task_id || m.task_id) === taskId)
    .slice()
    .sort((a, b) => String(a.ts).localeCompare(String(b.ts)))
}

/**
 * One §4.3 row → the shape the viewer renders. Also accepts the flat
 * first-message row of the earlier branch API (ts / updated_at / from / body).
 */
export function normalizeTopicRow(row) {
  const r = row || {}
  if (r.first_ts !== undefined || r.subject !== undefined) {
    return {
      task_id: String(r.task_id || ''),
      parent_task_id: hubField(r.parent_task_id),
      channel: hubField(r.channel),
      first_ts: r.first_ts || '',
      last_ts: r.last_ts || r.first_ts || '',
      count: Number(r.count) || 0,
      kinds: r.kinds || {},
      participants: Array.isArray(r.participants) ? r.participants : [],
      subject: String(r.subject || ''),
    }
  }
  const participants = [label(r.from, r.from_box), label(r.to, r.to_box)]
    .filter((p) => p && !p.startsWith('@'))
  return {
    task_id: String(r.task_id || ''),
    parent_task_id: hubField(r.parent_task_id),
    channel: hubField(r.channel),
    first_ts: r.ts || '',
    last_ts: r.updated_at || r.ts || '',
    count: Number(r.count) || 0,
    kinds: r.kind ? { [r.kind]: 1 } : {},
    participants,
    subject: subjectOf(r.body),
  }
}

/**
 * One §4.4 element ({ cursor, received_at, env: { from_box, to_box, channel?,
 * parent_task_id?, msg, sig }, deliveries }) → a flat v:1 message plus
 * from_box / to_box / channel / parent_task_id. A flat element (already v:1 +
 * boxes) passes through. The envelope sig is dropped.
 */
export function normalizeViewMessage(el) {
  const e = el || {}
  if (e.env && typeof e.env === 'object') {
    const inner = e.env.msg && typeof e.env.msg === 'object' ? e.env.msg : {}
    const out = {
      ...inner,
      from_box: e.env.from_box,
      to_box: e.env.to_box,
      channel: hubField(e.env.channel),
      parent_task_id: hubField(e.env.parent_task_id),
    }
    if (e.cursor !== undefined) out.cursor = e.cursor
    if (e.received_at !== undefined) out.received_at = e.received_at
    if (Array.isArray(e.deliveries)) out.deliveries = e.deliveries
    copyEditFields(e, out)
    /* specs/036 FR-011: hub metadata beside the envelope, omitted when absent */
    if (typeof e.typed_by === 'string' && e.typed_by) out.typed_by = e.typed_by
    if (e.is_parent === 0 || e.is_parent === 1) out.is_parent = e.is_parent
    if (Array.isArray(e.reactions)) out.reactions = normalizeReactions(e.reactions)
    delete out.sig
    return out
  }
  const out = { ...e }
  delete out.sig
  if (Array.isArray(out.reactions)) out.reactions = normalizeReactions(out.reactions)
  return out
}

/**
 * message-edit-v1 §6 — the edit marker rides BESIDE the envelope, at the
 * element's top level next to `cursor` and `received_at`, NOT inside
 * `env.msg`. This function is allow-listed like its neighbours, so without
 * this call the three keys are dropped on the floor and the "(edited)" marker
 * never renders. The keys are omitted entirely until a message has been
 * edited (§2), so each one is copied only when present — writing
 * `out.edited_at = undefined` would turn "never edited" into a key that
 * exists, which is the very thing the marker tests for.
 */
export function copyEditFields(src, out) {
  const e = src || {}
  if (e.edited_at !== undefined) out.edited_at = e.edited_at
  if (e.edited_by !== undefined) out.edited_by = e.edited_by
  if (e.revision !== undefined) out.revision = e.revision
  return out
}

/** Only a blob attachment has bytes on the hub (msg.go Attachment, mode "blob"). */
export function isDownloadable(file) {
  const f = file || {}
  if (f.mode === 'path') return false
  return Boolean(f.file_id || f.sha256)
}

/** wui-live-ws §1: the browser's virtual box — every human is an agent of it. */
export const BROWSER_BOX = 'box-wui'

const MEMBER_ID_RE = /^HUM-[0-9]+$/

/**
 * Map view-v1 §4.1 roster rows onto the roster store's { roster, online }.
 *
 * `humans` (§4.1, the tenant's members) is folded into the browser box, so a
 * member is a peer whether or not they happen to hold a socket right now.
 * CLE-3448: dropping it meant the people pane could only ever show a human
 * a live `presence` frame had just announced — and a reader who is the only
 * human signed in is exactly the one no frame announces to anybody else.
 *
 * Their ONLINE state is not ours to say: `/v1/view/roster` reports `online`
 * per BOX, and box-wui is never a live box session (it holds no key), so it
 * always reads `online: false`. Presence for a human comes from the socket
 * alone (wui-live-ws §3.2) and so is never put in `online` here.
 */
export function rosterFromView(data) {
  const roster = {}
  const online = []
  for (const b of (data && data.boxes) || []) {
    if (b.revoked) continue
    const agents = Array.isArray(b.agents) ? b.agents.slice() : []
    roster[b.box_id] = agents
    if (b.online) for (const a of agents) online.push(`${a}@${b.box_id}`)
  }
  const humans = ((data && data.humans) || [])
    .map((h) => String((h && h.human_id) || ''))
    .filter((id) => MEMBER_ID_RE.test(id))
  if (humans.length) roster[BROWSER_BOX] = [...new Set([...(roster[BROWSER_BOX] || []), ...humans])]
  return { roster, online }
}

/**
 * Map view-v1 §4.2 / channels-v1 §5.2 rows onto ChannelRow, keeping the hub's
 * unread / last_cursor / retention_days (the sidebar derives badges from them).
 */
export function channelsFromView(data) {
  return ((data && data.channels) || [])
    .filter((c) => c && c.channel)
    .map((c) => {
      const row = { channel_id: String(c.channel), name: String(c.name || c.channel) }
      if (c.description) row.description = String(c.description)
      if (c.created_by) row.created_by = String(c.created_by)
      if (c.created_at) row.created_at = String(c.created_at)
      if (c.default !== undefined) row.default = Boolean(c.default)
      if (typeof c.retention_days === 'number') row.retention_days = c.retention_days
      if (typeof c.count === 'number') row.count = c.count
      if (typeof c.unread === 'number') row.unread = c.unread
      if (c.last_ts !== undefined) row.last_ts = hubField(c.last_ts)
      if (c.last_cursor !== undefined) row.last_cursor = hubField(c.last_cursor)
      if (c.members && typeof c.members === 'object') {
        row.members = {
          agents: Number(c.members.agents) || 0,
          boxes: Number(c.members.boxes) || 0,
          posters: Number(c.members.posters) || 0,
        }
      }
      return row
    })
}

/**
 * channels-v1 §5.2 `read=<channel>~<cursor>` values from { channel: cursor }
 * (read state is client-held, OQ-CH2). Empty cursors are skipped.
 */
export function channelReadQuery(read) {
  const out = []
  for (const [ch, cur] of Object.entries(read || {})) {
    if (ch && cur) out.push(`${ch}~${cur}`)
  }
  return out
}
