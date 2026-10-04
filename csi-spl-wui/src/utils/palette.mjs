/**
 * 081 FR-003, FR-004: the command palette's ranker, query parser and recents.
 *
 * Pure and device-neutral: no DOM, no Vue. An item is `{ id, label,
 * keywords? }`; the sources (T003) build them, the dialog (T004) shows them.
 * Ranking: the label (or a keyword) equals the query, then starts with it,
 * then has a word that starts with it, then contains it; within a tier a
 * recently used item comes first (newest first), then the sources' order.
 * Recents live in the browser under `spool.palette-recent`, newest first,
 * at most 20 ids; `store` is any Storage-shaped object (see prefs.mjs).
 */
import { storageGetJson, storageSetJson } from './prefs.mjs'

export const PALETTE_RECENT_KEY = 'spool.palette-recent'
export const PALETTE_RECENT_MAX = 20

/** Tiers, best first; NO_MATCH drops the item. */
export const TIER_EXACT = 0
export const TIER_PREFIX = 1
export const TIER_WORD = 2
export const TIER_SUBSTRING = 3
const NO_MATCH = -1

const WORD_SPLIT = /[^\p{L}\p{N}]+/u

function norm(s) {
  return String(s ?? '').trim().toLowerCase()
}

/**
 * The palette input split into its mode and text: a leading `>` is the
 * actions mode (spec 3.1), anything else navigates.
 * @param {unknown} raw
 * @returns {{ mode: 'go' | 'actions', text: string }}
 */
export function parseQuery(raw) {
  const s = String(raw ?? '').trimStart()
  if (s.startsWith('>')) return { mode: 'actions', text: s.slice(1).trim() }
  return { mode: 'go', text: s.trim() }
}

/**
 * How well one string matches a lower-cased, non-empty query.
 * @param {unknown} text
 * @param {string} q
 * @returns {number}  a TIER_* constant, or -1 for no match
 */
function tierOf(text, q) {
  const t = norm(text)
  if (!t) return NO_MATCH
  if (t === q) return TIER_EXACT
  if (t.startsWith(q)) return TIER_PREFIX
  if (t.split(WORD_SPLIT).some((w) => w && w.startsWith(q))) return TIER_WORD
  if (t.includes(q)) return TIER_SUBSTRING
  return NO_MATCH
}

/**
 * The best tier of an item over its label and keywords.
 * @param {{ label?: unknown, keywords?: unknown }} item
 * @param {unknown} query
 * @returns {number}  a TIER_* constant, or -1 for no match (also for an empty query)
 */
export function matchTier(item, query) {
  const q = norm(query)
  if (!q || !item) return NO_MATCH
  const texts = [item.label, ...(Array.isArray(item.keywords) ? item.keywords : [])]
  let best = NO_MATCH
  for (const text of texts) {
    const tier = tierOf(text, q)
    if (tier !== NO_MATCH && (best === NO_MATCH || tier < best)) best = tier
  }
  return best
}

function recentRanks(recent) {
  const ranks = new Map()
  if (!Array.isArray(recent)) return ranks
  recent.forEach((id, i) => {
    if (typeof id === 'string' && !ranks.has(id)) ranks.set(id, i)
  })
  return ranks
}

/**
 * The items that match `query`, best first (FR-003). An empty query gives
 * the recently used items, newest first. Items without an id are dropped.
 * The query is plain text: strip a `>` with parseQuery first.
 * @template {{ id: string, label: string, keywords?: string[] }} T
 * @param {readonly T[] | null | undefined} items
 * @param {unknown} query
 * @param {readonly string[] | null | undefined} [recent]  ids, newest first
 * @returns {T[]}
 */
export function rankItems(items, query, recent) {
  const list = (Array.isArray(items) ? items : []).filter((it) => it && typeof it.id === 'string' && it.id)
  const ranks = recentRanks(recent)
  if (!norm(query)) {
    return list.filter((it) => ranks.has(it.id)).sort((a, b) => ranks.get(a.id) - ranks.get(b.id))
  }
  const never = Number.MAX_SAFE_INTEGER
  return list
    .map((it, i) => ({ it, i, tier: matchTier(it, query), rank: ranks.get(it.id) ?? never }))
    .filter((r) => r.tier !== NO_MATCH)
    .sort((a, b) => a.tier - b.tier || a.rank - b.rank || a.i - b.i)
    .map((r) => r.it)
}

/**
 * The stored recents: ids, newest first, no duplicates, at most 20.
 * @param {Storage | undefined} store
 * @returns {string[]}
 */
export function loadRecent(store) {
  const raw = storageGetJson(PALETTE_RECENT_KEY, [], store)
  if (!Array.isArray(raw)) return []
  const seen = new Set()
  for (const id of raw) {
    if (typeof id === 'string' && id && !seen.has(id)) seen.add(id)
    if (seen.size >= PALETTE_RECENT_MAX) break
  }
  return [...seen]
}

/**
 * Record a use of `id`: it moves to the front, the list keeps 20.
 * @param {Storage | undefined} store
 * @param {unknown} id
 * @returns {string[]}  the new list (unchanged when `id` is empty)
 */
export function pushRecent(store, id) {
  const cur = loadRecent(store)
  if (typeof id !== 'string' || !id) return cur
  const next = [id, ...cur.filter((x) => x !== id)].slice(0, PALETTE_RECENT_MAX)
  storageSetJson(PALETTE_RECENT_KEY, next, store)
  return next
}
