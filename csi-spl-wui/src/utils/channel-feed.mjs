/** Pure feed helpers. Node tests import this file; Vue stores wrap it. */

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

export function formatBytes(n) {
  const v = Number(n) || 0
  if (v < 1024) return `${v} B`
  if (v < 1024 * 1024) return `${(v / 1024).toFixed(1)} KiB`
  return `${(v / (1024 * 1024)).toFixed(1)} MiB`
}

export function formatTs(ts) {
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return String(ts || '')
  return d.toISOString().slice(11, 16)
}

export function renderBody(src) {
  const escaped = String(src || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
  return escaped
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/@([A-Z]{2,4}-\d+)/g, '<span class="mention">@$1</span>')
    .replace(/\n/g, '<br>')
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
  const id = String((row && (row.channel_id || row.channel)) || '')
  if (id !== 'alerts') return ''
  const d = Number(row && row.retention_days)
  return `${Number.isFinite(d) && d > 0 ? d : 7} d`
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
 * msg_id → no-op. A reply to a thread row bumps its count; anything else
 * is appended as a new row. Returns a new array.
 */
export function mergeLive(rows, msg) {
  const m = msg || {}
  const list = rows || []
  if (!m.msg_id || list.some((r) => r.msg_id === m.msg_id)) return list
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
