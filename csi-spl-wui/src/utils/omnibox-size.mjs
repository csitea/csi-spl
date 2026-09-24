/** One row of the top-bar omnibox. Matches the textarea min-height. */
export const OMNIBOX_LINE_PX = 36

/**
 * Pixel height to paint when the omnibox is focused.
 * A drag is that size. Otherwise it is the height the field had before it
 * collapsed. A one-line field stays one line (null — the caller measures).
 * @param {number | null | undefined} userHeight drag, or null
 * @param {number | null | undefined} openHeight last open height, or null
 * @param {number} maxPx cap, already below the top bar
 * @returns {number | null}
 */
export function omniboxFocusHeight(userHeight, openHeight, maxPx) {
  const dragged = typeof userHeight === 'number' && userHeight > OMNIBOX_LINE_PX
  const saved = dragged ? userHeight : openHeight
  if (typeof saved !== 'number' || saved <= OMNIBOX_LINE_PX) return null
  const max = Math.max(OMNIBOX_LINE_PX, maxPx)
  return Math.min(max, Math.max(OMNIBOX_LINE_PX, Math.round(saved)))
}

/**
 * Height to keep when the field collapses to one line.
 * A one-line measurement clears a stored size only when the reader left it
 * that way. Collapsing a field that is already one line (blur after
 * Ctrl+Enter) keeps the stored size.
 * @param {{ userHeight?: number | null, openHeight?: number | null, measured: number, keep: boolean }} s
 * @returns {number | null}
 */
export function omniboxRememberHeight(s) {
  const userHeight = s.userHeight
  if (typeof userHeight === 'number' && userHeight > OMNIBOX_LINE_PX) return Math.round(userHeight)
  if (s.measured > OMNIBOX_LINE_PX) return Math.round(s.measured)
  if (s.keep) return typeof s.openHeight === 'number' ? s.openHeight : null
  return null
}
