/**
 * Reverse-prepend feed helpers (013, SPEC-spool-chat-reverse.md): display only.
 * Storage and the wire stay chronological; the WUI renders newest first.
 */

function when(m) {
  return String((m && (m.received_at || m.ts)) || '')
}

/** Newest first; ties broken by msg_id so the order is stable. */
export function newestFirst(messages) {
  return (messages || []).slice().sort((a, b) => {
    const c = when(b).localeCompare(when(a))
    return c !== 0 ? c : String(b.msg_id || '').localeCompare(String(a.msg_id || ''))
  })
}

/**
 * When a row LAST changed: a topic card's newest reply (`last_ts`),
 * else the message's own moment. A card sorted on this one moves back to the top
 * as soon as anyone replies inside it — sorting on `ts` alone leaves a busy
 * topic buried under newer but idle ones, which is what the owner saw on
 * /channel and /dm.
 */
export function activityOf(row) {
  return String((row && (row.last_ts || row.received_at || row.ts)) || '')
}

/** Newest ACTIVITY first (activityOf); ties broken by msg_id so it is stable. */
export function newestActivityFirst(rows) {
  return (rows || []).slice().sort((a, b) => {
    const c = activityOf(b).localeCompare(activityOf(a))
    return c !== 0 ? c : String(b.msg_id || '').localeCompare(String(a.msg_id || ''))
  })
}

/** The first `count` rows of a newest-first list, and whether older ones remain. */
export function windowed(rows, count) {
  const n = Math.max(0, Number(count) || 0)
  return { rows: rows.slice(0, n), hasOlder: rows.length > n }
}

/** Omnibox: `/search <q>` or `/search:<q>` (or `/s`) → { search: q }; `/search` alone → { search: '' }; else { send: text }. */
export function parseOmnibox(text) {
  const t = String(text || '')
  const m = t.match(/^\/(?:search|s)(?::|\s|$)([\s\S]*)$/i)
  if (m) return { search: (m[1] || '').trim() }
  return { send: t.trim() }
}

/** Case-insensitive match on body, author (id and id@box) and file names. */
export function matchesSearch(m, q) {
  const needle = String(q || '').trim().toLowerCase()
  if (!needle) return true
  const hay = [
    m && m.body,
    m && m.from,
    m && m.from && m.from_box ? `${m.from}@${m.from_box}` : '',
    ...((m && Array.isArray(m.files)) ? m.files.map((f) => f && f.name) : []),
  ].filter(Boolean).join('\n').toLowerCase()
  return hay.includes(needle)
}

/** Root of a topic = its oldest message; replies = the rest, newest first. */
export function rootAndReplies(messages) {
  const byAge = newestFirst(messages).reverse()
  const root = byAge[0] || null
  return { root, replies: newestFirst(byAge.slice(1)) }
}

/**
 * 013 US7 FR-013: merge rows by msg_id. A new msg_id is added; a row already
 * held as `pending` (our optimistic send) is replaced by the confirmed one;
 * any other duplicate is dropped. Returns the new list, what was added and
 * how many pending rows were confirmed.
 */
export function mergeById(rows, incoming) {
  const list = (rows || []).slice()
  const at = new Map(list.map((m, i) => [m.msg_id, i]))
  const added = []
  let confirmed = 0
  for (const m of incoming || []) {
    if (!m || !m.msg_id) continue
    const i = at.get(m.msg_id)
    if (i === undefined) {
      at.set(m.msg_id, list.length)
      list.push(m)
      added.push(m)
    } else if (list[i].pending && !m.pending) {
      list[i] = m
      confirmed++
    } else if (Array.isArray(m.reactions)) {
      /* A reload of a topic carries the emoji list. A live `message` frame
         does not, so a repeat of a confirmed row must not wipe a reaction
         that arrived on its own frame. */
      list[i] = { ...list[i], reactions: m.reactions }
    }
  }
  return { rows: list, added, confirmed }
}

/** The optimistic card for our own send (FR-013): shown at once, replaced by the pushed echo. */
export function pendingRow({ msg_id, task_id, from = '', to = '', kind = 'note', body = '', files = [], channel = null, parent_task_id = null, is_parent, now = new Date() }) {
  const row = {
    v: 1, msg_id, task_id, ts: now.toISOString(), received_at: now.toISOString(),
    from, from_box: 'box-wui', to: to || 'ALL-0', kind, body, files, channel, parent_task_id, pending: true,
  }
  if (is_parent === 0 || is_parent === 1) row.is_parent = is_parent
  return row
}

/** Drop one msg_id (a failed optimistic send). */
export function withoutMsg(rows, msgId) {
  return (rows || []).filter((m) => m.msg_id !== msgId)
}
