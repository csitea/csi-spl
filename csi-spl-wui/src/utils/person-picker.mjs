/* SPL-2213 (HUM-10, t1 cb2b515c): the person picker is a keyboard drop box.
   Typing shows the people whose name or id holds the typed letters, in any
   case; Up / Down move the highlight; Enter picks it. PersonPicker.vue is the
   one component; these are its pure rules. */

/**
 * A case-insensitive "contains" on the person's name or id (a HUM id, an
 * agent id). An empty or blank query matches everyone.
 *
 * @param {{ id?: unknown, label?: unknown }} person
 * @param {unknown} query
 * @returns {boolean}
 */
export function personMatches(person, query) {
  const q = (typeof query === 'string' ? query : '').trim().toLowerCase()
  if (!q) return true
  return String(person?.label ?? '').toLowerCase().includes(q) || String(person?.id ?? '').toLowerCase().includes(q)
}

/**
 * The rows the open list shows for `query`, in their given order.
 *
 * @template {{ id: string, label: string }} T
 * @param {T[]} people
 * @param {unknown} query
 * @returns {T[]}
 */
export function personRows(people, query) {
  return (Array.isArray(people) ? people : []).filter((p) => personMatches(p, query))
}

/**
 * The highlight after an arrow: wraps at both ends; from none, Down goes to
 * the first row and Up to the last. No rows: none (-1).
 *
 * @param {number} active
 * @param {number} step +1 Down, -1 Up
 * @param {number} count
 * @returns {number}
 */
export function stepActive(active, step, count) {
  if (!(count > 0)) return -1
  if (!(active >= 0 && active < count)) return step > 0 ? 0 : count - 1
  return (active + step + count) % count
}

/**
 * The row Enter picks: the highlighted one, else the only row left.
 *
 * @template T
 * @param {T[]} rows
 * @param {number} active
 * @returns {T | null}
 */
export function enterPick(rows, active) {
  if (!Array.isArray(rows)) return null
  if (active >= 0 && active < rows.length) return rows[active]
  return rows.length === 1 ? rows[0] : null
}
