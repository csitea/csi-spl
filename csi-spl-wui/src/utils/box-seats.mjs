// The box card's two seat lists, apart from box-rows.mjs so the home bundle
// (the rail imports box-rows) carries none of it; only /boxes/<id> reads it.

/* HUM-10 (t1 58857a17): "N people · M agents" - each count a link to its own
   list on /boxes/<id> (owner: humans and agents "are fundamentally
   different"). These are the two lists' element ids, the links' hashes. */
export const SEATS_PEOPLE = 'box-people'
export const SEATS_AGENTS = 'box-agents'

/**
 * Which seats list a route hash opens: `#box-people` -> SEATS_PEOPLE,
 * `#box-agents` -> SEATS_AGENTS, anything else -> ''.
 * @param {unknown} hash
 * @returns {string}
 */
export function seatsAnchorOf(hash) {
  const h = String(hash || '').replace(/^#/, '')
  return h === SEATS_PEOPLE || h === SEATS_AGENTS ? h : ''
}
