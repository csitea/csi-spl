/**
 * Reverse-prepend feed helpers (013, SPEC-spool-chat-reverse.md): display only.
 * Storage and the wire stay chronological; the WUI renders newest first.
 */

function when(m) {
  return String((m && (m.received_at || m.ts)) || '')
}

/* Decorate-sort-undecorate: each row's sort keys (`when`/`activityOf` and the
   msg_id) are computed ONCE, not re-derived on every one of the O(n log n)
   comparisons. localeCompare and the msg_id tie-break are unchanged, so the
   order is identical - only the per-comparison string coercion is dropped. */

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
  return (rows || [])
    .map((row) => ({ row, k: activityOf(row), id: String(row.msg_id || '') }))
    .sort((a, b) => {
      const c = b.k.localeCompare(a.k)
      return c !== 0 ? c : b.id.localeCompare(a.id)
    })
    .map((d) => d.row)
}

/** The first `count` rows of a newest-first list, and whether older ones remain. */
export function windowed(rows, count) {
  const n = Math.max(0, Number(count) || 0)
  return { rows: rows.slice(0, n), hasOlder: rows.length > n }
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

/**
 * The optimistic card for our own send (FR-013): shown at once, replaced by the pushed echo.
 * @param {{ msg_id: string, task_id: string, from?: string, to?: string, kind?: string, body?: string, files?: unknown[], channel?: string | null, parent_task_id?: string | null, is_parent?: 0 | 1, now?: Date }} o
 */
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

/** feed.mjs's half sorts on the same moment. */
export { when as feedRowTime }
