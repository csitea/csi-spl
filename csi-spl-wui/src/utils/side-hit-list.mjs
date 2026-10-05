/**
 * CLE-77884 (Flow + Search rework, topic 635f8072): the pure half of
 * components/SideHitList.vue - the compact list the LEFT panel shows for
 * Search results (lane C) and Flow entries (lane B). The list stays while the
 * reader clicks through; each entry opens its message in its original place.
 *
 * An item: { key, group?, who?: { id, box? }, where?, when?, segs?, text?,
 *            badge?, title?, unread? }
 *   group  a heading label; consecutive items with the same group share one
 *   segs   [{ text, mark }] - the snippet with the match marked (search)
 *   text   the plain snippet when there is no segs (flow)
 *   badge  the where-icon: '#' channel, '@' DM, '↳' thread reply
 *   title  the full text, as a tooltip
 */

/** The next active index for a key over `n` items (wrapping), -1 for none. */
export function cycleIndex(i, n, key) {
  if (!n) return -1
  const cur = Number.isInteger(i) && i >= 0 && i < n ? i : -1
  switch (key) {
    case 'ArrowDown': return (cur + 1) % n
    case 'ArrowUp': return cur <= 0 ? n - 1 : cur - 1
    case 'Home': return 0
    case 'End': return n - 1
    default: return cur
  }
}

/**
 * Consecutive items with one group label become one run, in order. Items
 * without a group form runs with group ''. Each item keeps its flat index,
 * which is what the keyboard walks.
 * @param {Array<{ key: string, group?: string }>} items
 * @returns {Array<{ group: string, items: Array<{ item: any, index: number }> }>}
 */
export function groupRuns(items) {
  const runs = []
  for (const [index, item] of (items || []).entries()) {
    const group = String(item.group || '')
    const last = runs[runs.length - 1]
    if (last && last.group === group) last.items.push({ item, index })
    else runs.push({ group, items: [{ item, index }] })
  }
  return runs
}

/** The snippet as marked segments: `segs` when given, else the plain `text`. */
export function itemSegments(item) {
  if (item && Array.isArray(item.segs) && item.segs.length) return item.segs
  const text = item && item.text ? String(item.text) : ''
  return text ? [{ text, mark: false }] : []
}
