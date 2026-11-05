/* spec 130 section 3.1 (owner HUM-10, t1 82dff03c, msgs 47ec5aab and
   6a0ec650): the Flow's member picker. Any member reads any person's or
   agent's whole Flow of the workspace; the page starts on the reader's own.
   The choice rides the address as ?flow=<id>, so a copied link opens that
   Flow (owner e04820a5); no ?flow= is the reader's own. FlowList.vue and
   stores/flow.ts use these pure rules. */

/** The query key that carries the chosen Flow. */
export const FLOW_MEMBER_QUERY = 'flow'

const PERSON_RX = /^(?:HUM|GST)-[0-9]+$/
/* the hub's flowAgentSQL / IsFlowAgent: an agent id with its box */
const AGENT_AT_BOX_RX = /^(?:[acgmoqu]-(?:00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|(?:CLE|AGY|GRK|QWN)-[0-9]+)@[a-z0-9][a-z0-9-]{0,31}$/

/**
 * A Flow member key the hub serves: a person's HUM-/GST- id, or an agent's
 * `<id>@<box>` (a bare agent id names no one box).
 *
 * @param {unknown} id
 * @returns {boolean}
 */
export function isFlowMemberKey(id) {
  const s = typeof id === 'string' ? id : ''
  return PERSON_RX.test(s) || AGENT_AT_BOX_RX.test(s)
}

/**
 * The member a route's ?flow= names, '' when none or not a member key (the
 * reader's own Flow).
 *
 * @param {Record<string, unknown> | null | undefined} query
 * @returns {string}
 */
export function flowMemberFromQuery(query) {
  const raw = query ? query[FLOW_MEMBER_QUERY] : ''
  const v = Array.isArray(raw) ? raw[0] : raw
  return isFlowMemberKey(v) ? String(v) : ''
}

/**
 * The query after picking `member`: ?flow=<member>, or none for the reader.
 *
 * @param {Record<string, unknown> | null | undefined} query the route's query
 * @param {string} member '' or the reader = the reader's own Flow
 * @param {string} self the reader's id
 * @returns {Record<string, unknown>}
 */
export function flowMemberQuery(query, member, self) {
  const next = { ...(query || {}) }
  if (!member || member === self) delete next[FLOW_MEMBER_QUERY]
  else next[FLOW_MEMBER_QUERY] = member
  return next
}

/**
 * The picker's options: the reader first, then the other persons, then the
 * agents (`<id>@<box>`), A-Z by label in each group; each id once.
 *
 * @param {{
 *   humans: string[],
 *   people: Array<{ id?: string, box?: string }>,
 *   self: string,
 *   label: (id: string) => string,
 *   meLabel: string,
 *   personsGroup: string,
 *   agentsGroup: string,
 * }} o
 * @returns {Array<{ id: string, label: string, group: string }>}
 */
export function flowMemberOptions(o) {
  const seen = new Set([o.self])
  const persons = []
  const agents = []
  const add = (list, id, group) => {
    if (!id || seen.has(id)) return
    seen.add(id)
    list.push({ id, label: o.label(id), group })
  }
  for (const id of o.humans || []) {
    if (PERSON_RX.test(id)) add(persons, id, o.personsGroup)
  }
  for (const p of o.people || []) {
    const id = String((p && p.id) || '')
    if (PERSON_RX.test(id)) add(persons, id, o.personsGroup)
    else if (p && p.box) {
      const key = `${id}@${p.box}`
      if (AGENT_AT_BOX_RX.test(key)) add(agents, key, o.agentsGroup)
    }
  }
  const byLabel = (a, b) => a.label.localeCompare(b.label)
  const me = o.self ? [{ id: o.self, label: o.meLabel, group: o.personsGroup }] : []
  return [...me, ...persons.sort(byLabel), ...agents.sort(byLabel)]
}
