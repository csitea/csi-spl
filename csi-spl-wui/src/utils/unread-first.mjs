/**
 * SPL-2506 (owner HUM-10, t1 43a1030f msgs 1c869ea9 + bfd1838c): "in any
 * listing whenever there are new msgs, they should be at the top or at the
 * bottom (depending on the settings of the user for pre or appending)", and
 * "the more unread msgs the upper or lower according to those settings the
 * msg card / object should get".
 *
 * So every listing (channels, DMs, a channel's topic cards, a thread's
 * replies, Issues) puts the items with unread at the edge new posts go to:
 * the top when the person's message order is newest first (prepend), the
 * bottom when it is newest last (append). The item with the most unread sits
 * at the very edge, then the next most; a tie goes to the newest unread
 * (`at`, an ISO time), nearest the edge. Items with 0 unread keep the order
 * the listing gives them today, so a list with nothing unread is unchanged.
 *
 * Pure and tiny, no imports: the sidebar's eager chunk reads it.
 *
 * @template T
 * @param {T[]} rows the listing in today's drawn order (top first)
 * @param {(row: T) => number} unreadOf a row's unread count (0 = read)
 * @param {{ atEnd?: boolean, at?: (row: T) => string }} [opts]
 *   atEnd: the group goes to the bottom (newest last); at: a row's newest
 *   unread time, for ties (default: today's order decides)
 * @returns {T[]} a new array; `rows` when nothing is unread
 */
export function unreadFirst(rows, unreadOf, opts = {}) {
  const list = Array.isArray(rows) ? rows : []
  const at = typeof opts.at === 'function' ? opts.at : null
  const hot = []
  const rest = []
  list.forEach((row, i) => {
    const n = Math.floor(Number(unreadOf(row))) || 0
    if (n > 0) hot.push({ row, n, i, t: at ? Date.parse(String(at(row) || '')) || 0 : 0 })
    else rest.push(row)
  })
  if (!hot.length) return list
  /* most unread first; then the newest unread; then today's order (top first, or bottom first at the end) */
  hot.sort((a, b) => b.n - a.n || b.t - a.t || (opts.atEnd ? b.i - a.i : a.i - b.i))
  const group = hot.map((h) => h.row)
  return opts.atEnd ? [...rest, ...group.reverse()] : [...group, ...rest]
}
