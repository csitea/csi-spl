/**
 * SPL-2430 (owner HUM-10, t1 89010926: "always the newest msgs ( which are
 * not seen should be displayed first ) or last depending on how the user
 * wants them"): a feed with unseen messages - a channel, a DM, a topic -
 * opens where they start, in either message order.
 *
 *   newest-last  the unseen block is at the bottom, read down: land the
 *                "new" divider (it sits before the first unseen) at the top
 *   newest-first the unseen block is at the top, the newest first: land
 *                its top row (the newest unseen) at the top
 */
import { firstUnreadId, isUnread } from './read-cursor.mjs'
import { isViewersOwn } from './typed-by.mjs'
import { scrollRowToTop } from './pane-scroll.mjs'

/**
 * The msg_id of the row a feed opens at, or '' when nothing is unseen (or
 * the feed was never read: no boundary, as the divider).
 *
 * @param {Array<{ msg_id?: string }>} rows the feed's rows in display order
 * @param {{ ts?: string, id?: string } | null | undefined} boundary the read cursor frozen at open
 * @param {string} selfId the reader (their own rows are never unseen)
 * @param {boolean} newestLast the reader's message order
 */
export function unreadLandingId(rows, boundary, selfId = '', newestLast = false) {
  if (!boundary || !boundary.ts) return ''
  if (newestLast) return firstUnreadId(rows, boundary, selfId)
  const top = (rows || []).find((m) => !isViewersOwn(m, selfId) && isUnread(m, boundary))
  return top ? String(top.msg_id || '') : ''
}

/** How long a landing is kept while the cards settle (ms). */
export const LANDING_HOLD_MS = 4000
const READER_INPUTS = ['wheel', 'touchstart', 'keydown', 'pointerdown']

/**
 * Keep a landing in place while the feed settles. The cards are laid out at
 * an estimate (content-visibility) and grow once drawn: 980 px within 15 ms
 * of the landing on the mock bundle (measured), which pushed the divider
 * off screen; a thread opening newest-last is also sent to its bottom once
 * mounted, after the landing. A phone pane is sized 0 until it is shown.
 * So land again on every size change of `watch` and every scroll of the
 * pane, until the reader acts (any input, on any pane), something else
 * scrolls the pane (`ownMove()` false: not the feed's own bottom glue), or
 * `ms` runs out. Lands once at once. Returns the function that stops it.
 *
 * @param {HTMLElement} scroller the pane that scrolls
 * @param {Array<Element | null | undefined>} watch the elements whose size moves the landing
 * @param {() => void} land puts the target back at the top
 * @param {() => boolean} ownMove the pane's position is the feed's own doing (its bottom glue)
 * @param {number} ms
 */
export function holdLanding(scroller, watch, land, ownMove = () => false, ms = LANDING_HOLD_MS) {
  if (!scroller) return () => {}
  land()
  if (typeof ResizeObserver !== 'function') return () => {}
  let at = scroller.scrollTop
  let frame = 0
  const again = () => {
    frame = 0
    /* moved by someone else since the last landing: theirs wins */
    if (Math.abs(scroller.scrollTop - at) > 1 && !ownMove()) return stop()
    land()
    at = scroller.scrollTop
  }
  /* landing inside the observer's callback re-sizes in the same frame (a
     "ResizeObserver loop" window error): land on the next frame instead */
  const soon = () => {
    if (!frame) frame = requestAnimationFrame(again)
  }
  const ro = new ResizeObserver(soon)
  const timer = setTimeout(() => stop(), ms)
  function stop() {
    clearTimeout(timer)
    if (frame) cancelAnimationFrame(frame)
    frame = 0
    ro.disconnect()
    scroller.removeEventListener('scroll', soon)
    for (const t of READER_INPUTS) window.removeEventListener(t, stop, true)
  }
  for (const t of READER_INPUTS) window.addEventListener(t, stop, { capture: true, passive: true })
  scroller.addEventListener('scroll', soon, { passive: true })
  ro.observe(scroller)
  for (const el of watch) if (el) ro.observe(el)
  return stop
}

/** A feed row by its msg_id, inside `root`, or null. */
export function rowEl(root, id) {
  return id && root ? root.querySelector(`[data-key="${CSS.escape(id)}"]`) : null
}

/**
 * Land a feed's unseen start and hold it (holdLanding): `target()` at the
 * top of the feed's pane (.feed-body), after `hold()` stops the pane's own
 * bottom glue. Null when the feed is not in a pane yet (an async pane
 * renders before it is in the page): land again once mounted.
 *
 * @param {HTMLElement | null | undefined} root the feed
 * @param {() => Element | null} target the row or divider to land
 * @param {() => void} hold stops the newest-last bottom glue
 * @param {() => boolean} newestLast the reader's message order
 * @returns {(() => void) | null} stops the hold
 */
export function landFeed(root, target, hold, newestLast) {
  const scroller = root ? root.closest('.feed-body') : null
  if (!scroller) return null
  return holdLanding(scroller, [root], () => {
    const el = target()
    if (!el) return
    hold()
    scrollRowToTop(scroller, el)
  }, () => newestLast() && scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight <= 2)
}
