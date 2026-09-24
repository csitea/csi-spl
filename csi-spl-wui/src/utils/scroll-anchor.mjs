/**
 * 013 US7 FR-012: keep the reading position when rows are prepended above
 * it. Pure; composables/useScrollAnchor.ts applies it to the DOM.
 */

/** A feed scrolled less than this from its top counts as "at the top". */
export const NEAR_TOP_PX = 80

/** How many keys now sit above the previous first key (0 = nothing prepended). */
export function prependedCount(prevKeys, nextKeys) {
  const first = (prevKeys || [])[0]
  if (first === undefined) return 0
  const i = (nextKeys || []).indexOf(first)
  return i > 0 ? i : 0
}

/**
 * After a prepend: at the top, new rows just enter (no pill); scrolled down,
 * the offset moves by how far the first visible row was pushed down
 * (`anchorBefore` → `anchorAfter`, viewport y), so the visible rows stay put
 * even when a windowed feed drops its oldest row at the bottom; without an
 * anchor row, by the height change. The pill counts the rows that arrived above.
 */
export function anchorAfterPrepend({ top = 0, prevHeight = 0, nextHeight = 0, anchorBefore = null, anchorAfter = null, added = 0, pill = 0, nearTop = NEAR_TOP_PX }) {
  if (added <= 0) return { top, pill, moved: false }
  if (top <= nearTop) return { top, pill: 0, moved: false }
  const shift = anchorBefore !== null && anchorAfter !== null ? anchorAfter - anchorBefore : nextHeight - prevHeight
  return { top: top + Math.max(0, shift), pill: pill + added, moved: true }
}

/**
 * The element that scrolls a feed: itself or the nearest ancestor with
 * overflow-y auto or scroll. A short list is still that scroller.
 * The document is only the fallback when nothing in the chain scrolls.
 */
export function scrollerOf(el, doc = globalThis.document) {
  for (let n = el || null; n; n = n.parentElement) {
    const oy = doc.defaultView.getComputedStyle(n).overflowY
    if (oy === 'auto' || oy === 'scroll') return n
  }
  return doc.scrollingElement || doc.documentElement
}

/**
 * The first row (`[data-key]` under `root`) whose top is at or below the
 * scroller's top edge (`edge`, viewport y): the row the reader is looking at.
 */
export function firstVisibleRow(root, edge) {
  for (const n of root ? root.querySelectorAll('[data-key]') : []) {
    if (n.getBoundingClientRect().top >= edge) return n
  }
  return null
}

/**
 * Layout y of an element (sum of offsetTop up the offsetParent chain).
 * Transforms do not move it, so a TransitionGroup FLIP (the inverse transform
 * it puts on moved rows during the update) cannot fool the anchor.
 */
export function layoutTop(el) {
  let y = 0
  for (let n = el; n; n = n.offsetParent) y += n.offsetTop || 0
  return y
}
