/* Feed helpers the lazy pages use; the entry chunk's half is in feed-core.mjs. */

import { feedRowTime as when } from './feed-core.mjs'

export { activityOf, matchesSearch, newestActivityFirst, pendingRow, windowed, withoutMsg } from './feed-core.mjs'

/** Newest first; ties broken by msg_id so the order is stable. */
export function newestFirst(messages) {
  return (messages || [])
    .map((m) => ({ m, k: when(m), id: String(m.msg_id || '') }))
    .sort((a, b) => {
      const c = b.k.localeCompare(a.k)
      return c !== 0 ? c : b.id.localeCompare(a.id)
    })
    .map((d) => d.m)
}

/** Omnibox: `/search <q>` or `/search:<q>` (or `/s`) → { search: q }; `/search` alone → { search: '' }; else { send: text }. */
export function parseOmnibox(text) {
  const t = String(text || '')
  const m = t.match(/^\/(?:search|s)(?::|\s|$)([\s\S]*)$/i)
  if (m) return { search: (m[1] || '').trim() }
  return { send: t.trim() }
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
