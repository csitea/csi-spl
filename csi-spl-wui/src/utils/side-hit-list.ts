/**
 * CLE-77884 (Flow + Search rework, topic 635f8072): the pure half of
 * components/SideHitList.vue - the compact list the LEFT panel shows for
 * Search results (lane C) and Flow entries (lane B). The list stays while the
 * reader clicks through; each entry opens its message in its original place.
 *
 * An item (SideHitItem):
 *   group  a heading label; consecutive items with the same group share one
 *   segs   [{ text, mark }] - the snippet with the match marked (search)
 *   text   the plain snippet when there is no segs (flow)
 *   badge  the where-icon: '#' channel, '@' DM, '↳' thread reply
 *   title  the full text, as a tooltip
 *   fold   a folded Flow line (spec 130): the text is clamped to 1 line, 3 on a phone
 *   ai     an AI agent posted it (SPL-2120): the entry carries the agent bar
 */

export type SideHitSeg = { text: string, mark: boolean }

export type SideHitItem = {
  key: string
  msgId?: string
  type?: string
  group?: string
  who?: { id: string, box?: string }
  where?: string
  when?: string
  segs?: SideHitSeg[]
  text?: string
  badge?: string
  title?: string
  unread?: boolean
  /** the clock the list is ordered by, stamped as data-ts */
  ts?: string
  /** spec 130: a folded Flow line - its text is clamped to 1 line (3 on a phone) */
  fold?: boolean
  /** SPL-2120: an AI agent posted it - the entry carries the agent bar */
  ai?: boolean
}

/** The next active index for a key over `n` items (wrapping), -1 for none. */
export function cycleIndex(i: number, n: number, key: string): number {
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
 */
export function groupRuns<T extends { key: string, group?: string }>(items: readonly T[] | null | undefined): Array<{ group: string, items: Array<{ item: T, index: number }> }> {
  const runs: Array<{ group: string, items: Array<{ item: T, index: number }> }> = []
  for (const [index, item] of (items || []).entries()) {
    const group = String(item.group || '')
    const last = runs[runs.length - 1]
    if (last && last.group === group) last.items.push({ item, index })
    else runs.push({ group, items: [{ item, index }] })
  }
  return runs
}

/** The snippet as marked segments: `segs` when given, else the plain `text`. */
export function itemSegments(item: { segs?: SideHitSeg[], text?: string } | null | undefined): SideHitSeg[] {
  if (item && Array.isArray(item.segs) && item.segs.length) return item.segs
  const text = item && item.text ? String(item.text) : ''
  return text ? [{ text, mark: false }] : []
}
