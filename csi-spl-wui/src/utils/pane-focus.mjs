/**
 * Which pane the reader selected last: the middle list or the right topic
 * pane. Owner, 2026-09-25: "whenever the last selected pane was the middle
 * pane ... typing on the omnibox and hitting enter should have created an
 * is_topic=1 msg, not a thread msg with is_topic=0".
 *
 * So an open right pane is not enough to make a send level 2. The right pane
 * takes the line only while it is the pane the reader was last in: opening a
 * topic (replies, a row click, Enter on a card) puts the reader there, and so
 * does a click or focus inside it. A click or focus in the middle moves them
 * back, and the next send starts a new topic. The sidebar, the top bar and a
 * pane divider leave the choice where it was.
 */

export const MIDDLE = 'middle'
export const RIGHT = 'right'

/**
 * The pane an event target sits in, or '' for anywhere that does not choose.
 * @param {unknown} el
 * @returns {'' | 'middle' | 'right'}
 */
export function paneOfTarget(el) {
  const e = /** @type {{ closest?: (s: string) => unknown } | null} */ (el)
  if (!e || typeof e.closest !== 'function') return ''
  if (e.closest('.pane-divider')) return ''
  if (e.closest('aside.live-pane')) return RIGHT
  if (e.closest('.spool-main')) return MIDDLE
  return ''
}

/**
 * Does the open right pane take the next Omnibox line? Only when it is open
 * and the middle was not the pane selected last. Unknown ('') counts as the
 * pane: a topic opened from a `?topic=` URL is the newest thing on screen.
 * @param {{ paneOpen?: boolean, lastPane?: string }} [opts]
 */
export function paneTakesLine({ paneOpen = false, lastPane = '' } = {}) {
  return Boolean(paneOpen) && lastPane !== MIDDLE
}
