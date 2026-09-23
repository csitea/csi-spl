/** @mention picker over the roster. Node tests import this file; Vue wraps it. */

const AGENT_ID_RE = /^(CLE|GRK|AGY|HUM|GST)-\d+$/

export function isAgentId(id) {
  return AGENT_ID_RE.test(String(id || ''))
}

/**
 * In-progress mention at the caret: an agent id, optionally `@box` (the roster
 * label `id@box`, which may still be partial). The value is the substring
 * after the opening @. Null when the caret is not in an @token.
 */
const MENTION_AT_RE = /(^|[\s])@([A-Za-z0-9-]*(?:@[A-Za-z0-9-]*)?)$/

export function activeMentionQuery(text, cursor) {
  const s = String(text || '')
  const n = Number(cursor)
  const i = Number.isFinite(n) ? Math.max(0, Math.min(s.length, n)) : s.length
  const m = s.slice(0, i).match(MENTION_AT_RE)
  if (!m) return null
  return m[2]
}

/**
 * Filter roster peers to CLE/GRK/AGY/HUM/GST ids matching the in-progress query.
 * Query may be 'CLE-07' or '@CLE-07'; empty query returns every allowed peer.
 */
export function filterRosterMentions(peers, query) {
  const rows = Array.isArray(peers) ? peers : []
  const allowed = rows.filter((p) => p && isAgentId(p.id))
  const q = String(query || '').replace(/^@+/, '').trim().toUpperCase()
  if (!q) return allowed.slice()
  return allowed.filter((p) => {
    const id = String(p.id || '').toUpperCase()
    const label = String(p.label || '').toUpperCase()
    return id.startsWith(q) || label.startsWith(q)
  })
}

/**
 * Replace the in-progress @token with `@token `. `id` is a bare agent id or
 * the roster label `id@box`. The whole typed token is replaced, so a trailing
 * `@box` is not left behind. parseMention routes on the bare id.
 */
export function insertMention(text, cursor, id) {
  const s = String(text || '')
  const n = Number(cursor)
  const i = Number.isFinite(n) ? Math.max(0, Math.min(s.length, n)) : s.length
  const before = s.slice(0, i)
  const after = s.slice(i)
  const m = before.match(MENTION_AT_RE)
  const start = m ? before.length - m[2].length - 1 : i
  const inserted = `@${id} `
  return { text: s.slice(0, start) + inserted + after, cursor: start + inserted.length }
}
