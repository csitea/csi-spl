/** @mention picker over the roster. Node tests import this file; Vue wraps it. */

const AGENT_ID_RE = /^(CLE|GRK|AGY|HUM|GST)-\d+$/

/* The @token at the caret: an id (CLE-07) or the start of a display name in
   any script (@first, @име), so a person is found by the name they chose. */
const MENTION_TOKEN_RE = /(^|[\s])@([\p{L}\p{N}._-]*)$/u

export function isAgentId(id) {
  return AGENT_ID_RE.test(String(id || ''))
}

/**
 * In-progress mention query at `cursor` (substring after @, no leading @).
 * Null when the caret is not in an @token (start-of-string or after whitespace).
 */
export function activeMentionQuery(text, cursor) {
  const s = String(text || '')
  const n = Number(cursor)
  const i = Number.isFinite(n) ? Math.max(0, Math.min(s.length, n)) : s.length
  const before = s.slice(0, i)
  const m = before.match(MENTION_TOKEN_RE)
  if (!m) return null
  return m[2]
}

/**
 * Filter roster peers to CLE/GRK/AGY/HUM/GST ids matching the in-progress query.
 * Query may be 'CLE-07' or '@CLE-07'; empty query returns every allowed peer.
 * The text matches any part of the id, the label, or the display name the
 * person chose (`names`, id -> name), case-insensitively: "3994" finds
 * CLE-3994, "last" finds the human named "FirstName LastName".
 *
 * @param {unknown[]} peers
 * @param {string} query
 * @param {Record<string, string> | null} [names]
 */
export function filterRosterMentions(peers, query, names = null) {
  const rows = Array.isArray(peers) ? peers : []
  const allowed = rows.filter((p) => p && isAgentId(p.id))
  const q = String(query || '').replace(/^@+/, '').trim().toLocaleLowerCase()
  if (!q) return allowed.slice()
  const nameOf = (id) => (names && typeof names === 'object' && Object.prototype.hasOwnProperty.call(names, id) ? String(names[id] || '') : '')
  return allowed.filter((p) => {
    const id = String(p.id || '').toLocaleLowerCase()
    const label = String(p.label || '').toLocaleLowerCase()
    const name = nameOf(String(p.id || '')).toLocaleLowerCase()
    return id.includes(q) || label.includes(q) || (name !== '' && name.includes(q))
  })
}

/**
 * #feedback (owner, 2026-09-25): the business owner(s) a member can tag,
 * online or not. `owners` are the roster's owner:true HUM-* ids (view-v1
 * §4.1). The reader never gets themself; the query filters like the agent
 * picker (id or chosen display name). Each row inserts the bare `HUM-n`,
 * which is what MENTION_RE / mentionsSelf notify on.
 */
export function ownerMentions(owners, query, names = null, selfId = '', isOnline = null) {
  const q = String(query || '').replace(/^@+/, '').trim().toLocaleLowerCase()
  const nameOf = (id) => (names && typeof names === 'object' && Object.prototype.hasOwnProperty.call(names, id) ? String(names[id] || '') : '')
  const seen = new Set()
  const out = []
  for (const raw of Array.isArray(owners) ? owners : []) {
    const id = String(raw || '')
    if (!/^HUM-\d+$/.test(id) || id === selfId || seen.has(id)) continue
    seen.add(id)
    const name = nameOf(id).toLocaleLowerCase()
    if (q && !id.toLocaleLowerCase().includes(q) && !(name !== '' && name.includes(q))) continue
    out.push({ id, box: 'box-wui', label: id, owner: true, online: typeof isOnline === 'function' ? Boolean(isOnline(id)) : false })
  }
  return out
}

/**
 * Replace the in-progress @token with the full tag. `id` is the roster label
 * (`CLE-3994@box-desk`) or a bare id. Enter on `@3994` therefore writes the
 * whole tag, not the fragment that was typed.
 */
export function insertMention(text, cursor, id) {
  const s = String(text || '')
  const n = Number(cursor)
  const i = Number.isFinite(n) ? Math.max(0, Math.min(s.length, n)) : s.length
  const before = s.slice(0, i)
  const after = s.slice(i)
  const m = before.match(MENTION_TOKEN_RE)
  const start = m ? before.length - m[2].length - 1 : i
  const inserted = `@${id} `
  return { text: s.slice(0, start) + inserted + after, cursor: start + inserted.length }
}
