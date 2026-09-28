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

/*
 * Newest LAST (Settings -> Behaviour "Message order", topic c6994436): the
 * mirror image. New rows are appended at the bottom, older pages load at the
 * top, and the reader who sits at the bottom stays glued to it.
 */

/** A feed scrolled less than this from its bottom counts as "at the bottom". */
export const NEAR_BOTTOM_PX = 80

/** How far the scroller's view is from its bottom (0 = at the bottom). */
export function distanceFromBottom({ top = 0, height = 0, client = 0 }) {
  return Math.max(0, height - top - client)
}

/** How many keys now sit below the previous last key (0 = nothing appended). */
export function appendedCount(prevKeys, nextKeys) {
  const prev = prevKeys || []
  const last = prev[prev.length - 1]
  if (last === undefined) return 0
  const next = nextKeys || []
  const i = next.indexOf(last)
  return i >= 0 ? next.length - 1 - i : 0
}

/**
 * true when `nextKeys` is a different list, not a change of the same one:
 * the first rows arrived, or no previous key survived (another topic opened
 * in the same pane). Such a feed lands at its bottom.
 */
export function isFreshList(prevKeys, nextKeys) {
  const prev = prevKeys || []
  const next = nextKeys || []
  if (!next.length) return false
  if (!prev.length) return true
  const keep = new Set(next)
  return !prev.some((k) => keep.has(k))
}

/**
 * After a change of a newest-last feed.
 * - our own send, or a reader at the bottom: go to the bottom, no pill;
 * - scrolled up: the first visible row stays where it was on screen
 *   (`anchorBefore` -> `anchorAfter`, layout y), so an older page loaded
 *   above, or the window dropping its oldest row at the top, does not move
 *   what the reader looks at; the pill counts the rows appended below.
 * @returns {{ bottom: boolean, top: number, pill: number }}
 */
export function anchorAfterAppend({ top = 0, atBottom = false, own = false, anchorBefore = null, anchorAfter = null, added = 0, pill = 0 }) {
  if (own || atBottom) return { bottom: true, top, pill: 0 }
  const shift = anchorBefore !== null && anchorAfter !== null ? anchorAfter - anchorBefore : 0
  return { bottom: false, top: top + shift, pill: pill + Math.max(0, added) }
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
