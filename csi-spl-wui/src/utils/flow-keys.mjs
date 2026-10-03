/**
 * Owner (t1 77540e6f): "the amount of unread messages total ... should be
 * comprised of" the unread of each row it lists. The hub's Flow `keys`
 * (contract specs/062-flow-per-user-counts/contracts/flow-v1.md section 2)
 * are the unread per row - ch:<channel>, dm:<peer>, t:<task_id> - and the
 * sidebar draws both the row badges and the section numbers from them, here.
 * Pure and tiny, no imports: it rides the sidebar's eager chunk.
 */

function whole(v) {
  const n = Math.floor(Number(v))
  return Number.isFinite(n) && n > 0 ? n : 0
}

/**
 * A section's number: the sum of `keys` over the rows it lists (each id
 * once), so the number is never more than the badges on its rows add up to.
 * @param {Record<string, number> | null} keys
 * @param {'ch:' | 'dm:' | 't:'} prefix
 * @param {Iterable<string>} ids the listed rows' ids (channel id, peer label, task id)
 */
export function sectionTotal(keys, prefix, ids) {
  if (!keys) return 0
  let sum = 0
  for (const id of new Set(ids)) sum += whole(keys[prefix + id])
  return sum
}

/**
 * A row's unread: the hub's keys once it sent them, else the row's own
 * count (an older hub).
 * @param {Record<string, number> | null} keys
 * @param {Record<string, number>} own
 * @param {string} key
 */
export function rowUnread(keys, own, key) {
  return keys ? whole(keys[key]) : whole(own && own[key])
}

/**
 * The DM peers with unread lines, as withDmPeers' activity map ({label: ''}):
 * a peer no roster lists any more (a retired agent) still gets a row, so a
 * new message counted in the total can always be opened and read.
 * @returns {Record<string, string>}
 */
export function flowDmPeers(keys) {
  const out = {}
  for (const k of Object.keys(keys || {})) {
    if (k.startsWith('dm:') && whole(keys[k])) out[k.slice(3)] = ''
  }
  return out
}
