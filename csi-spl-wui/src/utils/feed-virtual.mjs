/**
 * SPL-2146: the channel feed renders only the rows near the viewport.
 *
 * WHY: a feed shows 30 rows and grows by 30 per Load more, and every row it
 * shows stays in the DOM. Measured on the mock bundle (master c65a1e9a4,
 * #alerts with 2000 rows, 66 Load more): 2000 cards, 72005 nodes under
 * .feed-body, 45.6 s and 126.9 s to draw on a loaded box (n=2). Below
 * VIRTUAL_MIN rows nothing changes: the first page and the next few render
 * whole, as before. From VIRTUAL_MIN on, the rows a viewport and OVERSCAN_PX
 * above and below it render, and two spacers stand for the rest.
 *
 * Pure: the feed (useFeedWindow) measures, this module only adds up.
 */

/** Rows a feed holds before it windows them (four pages of 30). */
export const VIRTUAL_MIN = 120
/** A row not drawn yet counts this tall until it has been measured. */
export const EST_ROW_PX = 140
/** Room drawn above and below the viewport. */
export const OVERSCAN_PX = 1200

/**
 * The rows to draw for a viewport.
 * sizes: each row's height in px, in DOM order. viewTop / viewBottom: the
 * viewport's edges in the same coordinates (0 = the top of the first row).
 * Returns { start, end, top, bottom }: draw rows [start, end); `top` and
 * `bottom` are the px the rows before and after them take.
 * @param {{ sizes?: number[], viewTop?: number, viewBottom?: number, overscan?: number }} [o]
 * @returns {{ start: number, end: number, top: number, bottom: number }}
 */
export function feedRange({ sizes = [], viewTop = 0, viewBottom = 0, overscan = OVERSCAN_PX } = {}) {
  const n = sizes.length
  const lo = viewTop - overscan
  const hi = viewBottom + overscan
  let y = 0
  let start = 0
  while (start < n - 1 && y + sizes[start] <= lo) y += sizes[start++]
  const top = y
  let end = start
  while (end < n && (end === start || y < hi)) y += sizes[end++]
  let bottom = 0
  for (let i = end; i < n; i++) bottom += sizes[i]
  return { start, end, top, bottom }
}

/**
 * The px before row `index`.
 * @param {number[]} sizes
 * @param {number} index
 */
export function offsetOf(sizes = [], index = 0) {
  let y = 0
  for (let i = 0; i < index && i < sizes.length; i++) y += sizes[i]
  return y
}

/**
 * The height a row not measured yet counts: the mean of the measured ones,
 * else EST_ROW_PX. The feed takes it ONCE: a mean that moved with every row
 * measured would move the rows under a 2000-row spacer by tens of
 * thousands of px.
 * @param {Map<string, number>} heights
 */
export function estimateOf(heights = new Map()) {
  let sum = 0
  let n = 0
  for (const h of heights.values()) { sum += h; n += 1 }
  return n ? sum / n : EST_ROW_PX
}

/**
 * Each row's height: the measured one, else `est`.
 * keys: the rows in DOM order; heights: Map key -> px.
 * @param {string[]} keys
 * @param {Map<string, number>} heights
 * @param {number} [est]
 * @returns {number[]}
 */
export function rowSizes(keys = [], heights = new Map(), est = EST_ROW_PX) {
  return keys.map((k) => heights.get(k) ?? est)
}

/**
 * The height each drawn row takes in the list: the distance to the next
 * row's top, and for the last one its own height plus the gap before it.
 * tops / heights: the drawn rows' offsetTop and offsetHeight, in DOM order.
 * @param {number[]} tops
 * @param {number[]} heights
 * @returns {number[]}
 */
export function slotHeights(tops = [], heights = []) {
  const out = []
  let gap = 0
  for (let i = 0; i < tops.length; i++) {
    if (i + 1 < tops.length) {
      const slot = tops[i + 1] - tops[i]
      gap = Math.max(0, slot - heights[i])
      out.push(slot)
    } else out.push(heights[i] + gap)
  }
  return out
}
