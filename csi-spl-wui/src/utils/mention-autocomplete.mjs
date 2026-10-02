/** @mention picker over the roster. Node tests import this file; Vue wraps it. */

import { agentKindOf } from './agent-id.mjs'

const HUMAN_RE = /^(HUM|GST)-[0-9]+$/

/* The @token at the caret: an id (CLE-07) or the start of a display name in
   any script (@first, @име), so a person is found by the name they chose. */
const MENTION_TOKEN_RE = /(^|[\s])@([\p{L}\p{N}._-]*)$/u

export function isAgentId(id) {
  /* a known kind (c-004, CLE-07, ...) or a person; EZB-1 / ALL-0 are not offered */
  const s = String(id || '')
  return agentKindOf(s) !== 'agent' || HUMAN_RE.test(s)
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

/**
 * SPL-985 (spec 042 P1): the one list every text field shows on `@` - the
 * tenant's agents and people. `peers` is the roster (agents, and the people
 * online on box-wui); `names` adds every member who chose a display name, and
 * `owners` every business owner, so a person who is offline is still found.
 * The reader is never offered. In #feedback (`ownersFirst`) the owners lead.
 *
 * @param {{ peers?: unknown[], names?: Record<string, string> | null, owners?: string[],
 *   selfId?: string, query: string, ownersFirst?: boolean, isOnline?: ((id: string) => boolean) | null }} a
 */
export function mentionCandidates({ peers = [], names = null, owners = [], selfId = '', query, ownersFirst = false, isOnline = null }) {
  const agents = filterRosterMentions(peers, query, names).filter((p) => p.id !== selfId)
  const ownerRows = ownerMentions(owners, query, names, selfId, isOnline)
  const listed = new Set([...agents, ...ownerRows].map((p) => p.id))
  const q = String(query || '').replace(/^@+/, '').trim().toLocaleLowerCase()
  const people = []
  for (const [id, name] of Object.entries(names && typeof names === 'object' ? names : {})) {
    if (!/^HUM-\d+$/.test(id) || id === selfId || listed.has(id)) continue
    if (q && !id.toLocaleLowerCase().includes(q) && !String(name || '').toLocaleLowerCase().includes(q)) continue
    listed.add(id)
    people.push({ id, box: 'box-wui', label: id, online: typeof isOnline === 'function' ? Boolean(isOnline(id)) : false })
  }
  people.sort((a, b) => String(names[a.id] || a.id).localeCompare(String(names[b.id] || b.id)))
  return ownersFirst ? [...ownerRows, ...agents, ...people] : [...agents, ...people, ...ownerRows]
}

/* SPL-1009 (owner, 2026-09-27: "but still the humans are presented with
   IDs"): a field shows a picked person by the name they chose; what is STORED
   stays the tag (`@HUM-11@box-wui`), so a rename breaks no link and every
   reader (notify, poke, the renderer) keeps parsing ids. */

// bidi controls must not reorder the field around a name
const BIDI = /[؜‎‏‪-‮⁦-⁩]/g
const NAME_END = '(?![\\p{L}\\p{N}_-])'
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

function cleanName(names, id) {
  const has = names && typeof names === 'object' && Object.prototype.hasOwnProperty.call(names, id)
  return has ? String(names[id] || '').replace(BIDI, '').replace(/\s+/g, ' ').trim() : ''
}

/**
 * The name a member is written with in a field, or '' when the tag has to
 * stay: not a member (an agent keeps its id), no name chosen, a name another
 * member of the tenant also chose (the tag is what tells them apart), or a
 * name that would read as a tag itself.
 *
 * @param {string} id
 * @param {Record<string, string> | null | undefined} names
 */
export function mentionFieldName(id, names) {
  const who = String(id || '').split('@')[0]
  if (!/^HUM-\d+$/.test(who)) return ''
  const name = cleanName(names, who)
  if (!name || name.includes('@') || isAgentId(name)) return ''
  const key = name.toLocaleLowerCase()
  for (const other of Object.keys(names)) {
    if (other !== who && cleanName(names, other).toLocaleLowerCase() === key) return ''
  }
  return name
}

/**
 * The field text as stored: each `@<name>` a pick (or decodeMentions) wrote
 * becomes its tag again. Longest name first, so "Ann Lee" wins over "Ann".
 * Only names in `picks` change; an @word the person typed by hand is text.
 *
 * @param {string} text
 * @param {Record<string, string> | null | undefined} picks name -> tag (no '@')
 */
export function encodeMentions(text, picks) {
  let s = String(text || '')
  const labels = Object.keys(picks && typeof picks === 'object' ? picks : {}).filter(Boolean).sort((a, b) => b.length - a.length)
  for (const label of labels) {
    const re = new RegExp(`(^|\\s)@${escapeRe(label)}${NAME_END}`, 'gu')
    s = s.replace(re, (_m, pre) => `${pre}@${picks[label]}`)
  }
  return s
}

/**
 * A stored text made readable for editing: each `@HUM-n` / `@HUM-n@box-wui`
 * of a member with a name of their own reads `@<name>`. `picks` is what
 * encodeMentions needs to store it back unchanged.
 *
 * @param {string} text
 * @param {Record<string, string> | null | undefined} names
 * @returns {{ text: string, picks: Record<string, string> }}
 */
export function decodeMentions(text, names) {
  const picks = {}
  const out = String(text || '').replace(/(^|\s)@(HUM-\d+(?:@box-wui)?)(?![A-Za-z0-9@_.-])/g, (m, pre, tag) => {
    const name = mentionFieldName(tag, names)
    if (!name) return m
    if (picks[name] && picks[name] !== tag) return m
    picks[name] = tag
    return `${pre}@${name}`
  })
  return { text: out, picks }
}
