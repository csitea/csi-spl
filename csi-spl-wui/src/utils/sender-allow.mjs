/**
 * SPL-1018 (spec 044 FR-OS-017, owner t1 dee4081d msg e9ec66fa): the rules of
 * Workspace settings -> Agents -> "Who may message each agent". A workspace
 * admin keeps, per agent, the members who may DM or @mention it; an agent
 * with no list takes messages from every member (decision 2). The hub
 * refuses anyone else with 403 sender_not_allowed (send-failure.mjs).
 */

const str = (v) => (typeof v === 'string' ? v : '')

/**
 * A GET /v1/tenant/agent-senders body -> { <agent>: [HUM ids] }. An agent
 * absent from the map has no list (every member); [] is a list naming nobody.
 * @param {unknown} body
 * @returns {Record<string, string[]>}
 */
export function senderListsOf(body) {
  const b = /** @type {{ lists?: unknown } | null | undefined} */ (body)
  const out = /** @type {Record<string, string[]>} */ ({})
  for (const l of Array.isArray(b?.lists) ? b.lists : []) {
    const agent = str(l?.agent)
    if (!agent) continue
    out[agent] = (Array.isArray(l.members) ? l.members : []).filter((h) => typeof h === 'string' && h).sort()
  }
  return out
}

/**
 * The agent ids a list can be kept for: each seated agent once (the list is
 * per agent, whichever box it runs on), sorted.
 * @param {{ id: string }[]} seats
 */
export function senderAgents(seats) {
  return [...new Set((seats || []).map((s) => str(s?.id)).filter(Boolean))].sort()
}

/**
 * What the row says about an agent: 'all' = no list, 'none' = a list naming
 * nobody, else 'some' with the count.
 * @param {string[] | undefined} list
 * @returns {{ state: 'all' | 'none' | 'some', n: number }}
 */
export function senderSummary(list) {
  if (!Array.isArray(list)) return { state: 'all', n: 0 }
  return list.length ? { state: 'some', n: list.length } : { state: 'none', n: 0 }
}

/**
 * The save of an edit: mode 'all' drops the list, 'list' puts the ticked
 * members (sorted, once each). null = nothing changed.
 * @param {string[] | undefined} saved
 * @param {'all' | 'list'} mode
 * @param {string[]} ticked
 * @returns {{ op: 'drop' } | { op: 'put', members: string[] } | null}
 */
export function senderSave(saved, mode, ticked) {
  if (mode === 'all') return Array.isArray(saved) ? { op: 'drop' } : null
  const members = [...new Set(ticked || [])].sort()
  if (Array.isArray(saved) && saved.join(',') === members.join(',')) return null
  return { op: 'put', members }
}
