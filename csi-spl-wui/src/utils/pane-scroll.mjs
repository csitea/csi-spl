/**
 * Bring `row` to the top of `scroller` only.
 * `scroller.scrollTop += rowTop - scrollerTop`.
 * Callers must not use scrollIntoView: that also scrolls the document.
 */
export function scrollRowToTop(scroller, row) {
  if (!scroller || !row) return
  const rowTop = row.getBoundingClientRect().top
  const scrollerTop = scroller.getBoundingClientRect().top
  scroller.scrollTop += rowTop - scrollerTop
}

/**
 * CLE-77840: bring `row` just inside `scroller` (the "nearest" edge), for the
 * ArrowDown / ArrowUp walk through a feed. Only the scroller moves: a row
 * already fully visible moves nothing, one below comes up to the bottom edge,
 * one above comes down to the top edge. Never the document (scrollIntoView).
 */
export function scrollRowIntoPane(scroller, row) {
  if (!scroller || !row) return
  const r = row.getBoundingClientRect()
  const s = scroller.getBoundingClientRect()
  if (r.top < s.top) scroller.scrollTop += r.top - s.top
  else if (r.bottom > s.bottom) scroller.scrollTop += Math.min(r.bottom - s.bottom, r.top - s.top)
}

/**
 * Open a row that lives in a thread. Focus does not scroll.
 * The thread scroller's scrollTop is not read or written: the pane stays
 * where the reader left it, including at the top when it has just opened.
 */
export function openThreadRow(row) {
  if (!row || typeof row.focus !== 'function') return
  row.focus({ preventScroll: true })
}
