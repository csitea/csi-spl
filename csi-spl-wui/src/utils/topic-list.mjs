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
  /* is_parent 0 is a reply from the open topics pane. It may bump a topic
     already on the list. It never starts a row of its own. */
  if (m.is_parent === 0 && i < 0) return list
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

/**
 * Reconnect catch-up: a fresh first page replaces rows by task_id, keeps older
 * pages. A held row the page SHOULD have carried - its last_ts inside the
 * page's own span - and did not is gone from the list on the hub (archived,
 * deleted or merged while this tab was away, t1 8fb802cd): it goes here too,
 * or an archived topic sits among the live ones until a reload. A row newer
 * than the page (a live bump that raced the read) or older (a later page) is
 * kept.
 */
export function mergeTopicPage(topics, page) {
  const fresh = (page || []).filter((t) => t && t.task_id)
  const byId = new Map((topics || []).map((t) => [t.task_id, t]))
  if (fresh.length) {
    const stamps = fresh.map((t) => String(t.last_ts || '')).sort()
    const floor = stamps[0]
    const ceiling = stamps[stamps.length - 1]
    const listed = new Set(fresh.map((t) => t.task_id))
    for (const [id, t] of byId) {
      const ts = String(t.last_ts || '')
      if (!listed.has(id) && ts >= floor && ts <= ceiling) byId.delete(id)
    }
  }
  for (const t of fresh) byId.set(t.task_id, t)
  return [...byId.values()].sort(byNewest)
}
