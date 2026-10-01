// CLE-77871 (CLE-001 on owner topic f20c6052): after Undo on an "<what> ·
// Undo" snackbar (Archived, Deleted, Moved) the card that came back is
// SELECTED again, as it was before the action: it takes the focus with the
// focus-visible highlight (main.css `.msg:focus-visible`) and its feed scrolls
// it into view. Never the document (pane-scroll.mjs).
//
// The row is re-rendered by the feeds' re-read, so it is awaited (polled) for
// a short while; a row that never comes back (its feed was closed, another
// route) selects nothing. Pure DOM, timers injected, so the unit test drives it.
import { scrollRowIntoPane } from './pane-scroll.mjs'
import { scrollerOf } from './scroll-anchor.mjs'

/** How long the re-read may take to bring the row back. */
export const RESELECT_WAIT_MS = 3000
const EVERY_MS = 50

/** The pane a row sits in: 'topic' (the right pane) or 'main'. */
export function paneOfRow(el) {
  if (!el || typeof el.closest !== 'function') return ''
  return el.closest('.topic') ? 'topic' : 'main'
}

/** The pane the row `msgId` is in now ('' = not on screen). */
export function paneOfMsg(msgId, doc = globalThis.document) {
  if (!doc || !msgId) return ''
  return paneOfRow(doc.querySelector(`article.msg[data-msg-id="${cssId(msgId)}"]`))
}

function cssId(id) {
  return String(id).replace(/["\\]/g, '\\$&')
}

/** The rendered row for `msgId`, preferring the pane it was in. */
export function findRow(msgId, pane = '', doc = globalThis.document) {
  if (!doc || !msgId) return null
  const sel = `article.msg[data-msg-id="${cssId(msgId)}"]`
  const scopes = pane === 'topic' ? ['.topic ', '.spool-main ', ''] : pane === 'main' ? ['.spool-main ', '.topic ', ''] : ['.spool-main ', '.topic ', '']
  for (const scope of scopes) {
    const el = [...doc.querySelectorAll(scope + sel)].find((e) => e.getClientRects().length)
    if (el) return el
  }
  return null
}

/** Focus `row` as the selected one and scroll its feed (not the page) to it. */
export function selectRow(row, doc = globalThis.document) {
  if (!row || typeof row.focus !== 'function') return false
  try {
    row.focus({ preventScroll: true, focusVisible: true })
  } catch {
    row.focus()
  }
  const scroller = scrollerOf(row, doc)
  if (scroller && scroller !== doc.scrollingElement && scroller !== doc.documentElement) scrollRowIntoPane(scroller, row)
  return true
}

/**
 * Wait (<= `wait` ms) for the row `msgId` to be back, then select it.
 * Resolves true when it was selected.
 */
export function reselectRow(msgId, { pane = '', doc = globalThis.document, wait = RESELECT_WAIT_MS, set = setTimeout } = {}) {
  const id = String(msgId || '')
  if (!id || !doc) return Promise.resolve(false)
  return new Promise((resolve) => {
    let waited = 0
    const tick = () => {
      const row = findRow(id, pane, doc)
      if (row) return resolve(selectRow(row, doc))
      if (waited >= wait) return resolve(false)
      waited += EVERY_MS
      set(tick, EVERY_MS)
    }
    tick()
  })
}
