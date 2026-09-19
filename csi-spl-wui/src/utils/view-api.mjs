/**
 * Pure helpers for the 003 read-only viewer API (specs/003 contracts/view-v1.md).
 * Node tests import this file; the client and stores wrap it.
 *
 * Thread = task_id (v:1, 002). `channel` / `parent_task_id` are hub-envelope
 * fields (channels-v1 §0, §2), never v:1 fields: the normalisers below lift
 * them off the envelope / thread row onto the flat message (null when absent,
 * spec 005 FR-005). The mock tenant still carries parent_task_id, so mock
 * grouping folds a reply into its root task.
 */

/** channels-v1 §2: absent, null and "" all mean absent → null. */
export function hubField(v) {
  return typeof v === 'string' && v ? v : null
}

const SUBJECT_MAX = 140

export function subjectOf(body) {
  const line = String(body || '').split('\n')[0].trim()
  return line.length > SUBJECT_MAX ? line.slice(0, SUBJECT_MAX) : line
}

function label(id, box) {
  if (!id) return ''
  return box ? `${id}@${box}` : String(id)
}

/** Group flat v:1 messages into view-v1 §4.3 rows, newest activity first. */
export function threadsFromMessages(messages) {
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

/** All messages of one thread, oldest first (mock side of view-v1 §4.4). */
export function threadMessages(messages, taskId) {
  return messages
    .filter((m) => (m.parent_task_id || m.task_id) === taskId)
    .slice()
    .sort((a, b) => String(a.ts).localeCompare(String(b.ts)))
}

/**
 * One §4.3 row → the shape the viewer renders. Also accepts the flat
 * first-message row of the earlier branch API (ts / updated_at / from / body).
 */
export function normalizeThreadRow(row) {
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
    delete out.sig
    return out
  }
  const out = { ...e }
  delete out.sig
  return out
}

/** Only a blob attachment has bytes on the hub (msg.go Attachment, mode "blob"). */
export function isDownloadable(file) {
  const f = file || {}
  if (f.mode === 'path') return false
  return Boolean(f.file_id || f.sha256)
}

/** Map view-v1 §4.1 roster rows onto the roster store's { roster, online }. */
export function rosterFromView(data) {
  const roster = {}
  const online = []
  for (const b of (data && data.boxes) || []) {
    if (b.revoked) continue
    const agents = Array.isArray(b.agents) ? b.agents.slice() : []
    roster[b.box_id] = agents
    if (b.online) for (const a of agents) online.push(`${a}@${b.box_id}`)
  }
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
