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
 * Open a row that lives in a thread. Focus does not scroll.
 * The thread scroller's scrollTop is not read or written: the pane stays
 * where the reader left it, including at the top when it has just opened.
 */
export function openThreadRow(row) {
  if (!row || typeof row.focus !== 'function') return
  row.focus({ preventScroll: true })
}
