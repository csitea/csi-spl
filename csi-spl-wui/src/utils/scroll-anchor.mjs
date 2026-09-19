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
 * the offset grows by the inserted height so the visible rows stay put, and
 * the pill counts the rows that arrived above.
 */
export function anchorAfterPrepend({ top = 0, prevHeight = 0, nextHeight = 0, added = 0, pill = 0, nearTop = NEAR_TOP_PX }) {
  if (added <= 0) return { top, pill, moved: false }
  if (top <= nearTop) return { top, pill: 0, moved: false }
  return { top: top + Math.max(0, nextHeight - prevHeight), pill: pill + added, moved: true }
}

/**
 * The element that actually scrolls a feed: the nearest ancestor with
 * overflow-y auto/scroll and content taller than itself, else the document
 * (a short window lets the page scroll instead of `.feed-body`).
 */
export function scrollerOf(el, doc = globalThis.document) {
  for (let n = el ? el.parentElement : null; n; n = n.parentElement) {
    const oy = doc.defaultView.getComputedStyle(n).overflowY
    if ((oy === 'auto' || oy === 'scroll') && n.scrollHeight > n.clientHeight + 1) return n
  }
  return doc.scrollingElement || doc.documentElement
}
