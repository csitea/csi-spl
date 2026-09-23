/**
 * 013 US7 FR-011: the topic list `/` newest first and live. A pushed
 * message (live-ws messageFromFrame shape) moves its topic row to the top,
 * or starts a new row; rows stay ordered by last_ts, newest first.
 */

function party(m, idKey, boxKey) {
  const id = String((m && m[idKey]) || '')
  const box = String((m && m[boxKey]) || '')
  return id && box ? `${id}@${box}` : id
}

function byNewest(a, b) {
  const c = String(b.last_ts || '').localeCompare(String(a.last_ts || ''))
  return c !== 0 ? c : String(b.task_id).localeCompare(String(a.task_id))
}

/**
 * Apply one live message. A reply inside a known topic bumps its count,
 * kinds, participants and last_ts; an unknown task_id becomes a new row
 * unless it is a child topic (parent_task_id: the list shows roots, §4.3).
 */
export function bumpTopic(topics, m) {
  const list = topics || []
  const id = String((m && m.task_id) || '')
  if (!id || !m.msg_id) return list
  const ts = String(m.received_at || m.ts || '')
  const who = [party(m, 'from', 'from_box'), party(m, 'to', 'to_box')].filter((p) => p && !/^ALL-0\b/.test(p))
  const i = list.findIndex((t) => t.task_id === id)
  let row
  if (i >= 0) {
    const t = list[i]
    /* The send and its own echo both carry this msg_id. Counting both would
       show two messages in a topic that has one. */
    if (t.last_msg_id && t.last_msg_id === m.msg_id) return list
    const kinds = { ...(t.kinds || {}) }
    if (m.kind) kinds[m.kind] = (kinds[m.kind] || 0) + 1
    row = { ...t, last_msg_id: m.msg_id, count: (Number(t.count) || 0) + 1, kinds, last_ts: ts > String(t.last_ts || '') ? ts : t.last_ts,
      participants: [...new Set([...(t.participants || []), ...who])] }
  } else {
    if (m.parent_task_id) return list
    row = { task_id: id, parent_task_id: null, channel: m.channel || null, first_ts: ts, last_ts: ts, count: 1,
      last_msg_id: m.msg_id,
      kinds: m.kind ? { [m.kind]: 1 } : {}, participants: [...new Set(who)], subject: String(m.body || '').split('\n')[0].slice(0, 120) }
  }
  const rest = list.filter((t) => t.task_id !== id)
  return [row, ...rest].sort(byNewest)
}

/** Reconnect catch-up: a fresh first page replaces rows by task_id, keeps older pages. */
export function mergeTopicPage(topics, page) {
  const byId = new Map((topics || []).map((t) => [t.task_id, t]))
  for (const t of page || []) if (t && t.task_id) byId.set(t.task_id, t)
  return [...byId.values()].sort(byNewest)
}
