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

/** The first `count` rows of a newest-first list, and whether older ones remain. */
export function windowed(rows, count) {
  const n = Math.max(0, Number(count) || 0)
  return { rows: rows.slice(0, n), hasOlder: rows.length > n }
}

/** Omnibox: `/search <q>` (or `/s <q>`) → { search: q }; `/search` alone → { search: '' }; else { send: text }. */
export function parseOmnibox(text) {
  const t = String(text || '')
  const m = t.match(/^\/(?:search|s)(?:\s+([\s\S]*))?$/i)
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

/** Root of a thread = its oldest message; replies = the rest, newest first. */
export function rootAndReplies(messages) {
  const byAge = newestFirst(messages).reverse()
  const root = byAge[0] || null
  return { root, replies: newestFirst(byAge.slice(1)) }
}
