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

/**
 * Inline-start space the ONE-LINE omnibox reserves for the glyph and the
 * target chip. The multi-line layout drops this indent; the caller still
 * passes it so a wrap is judged against the box the text has while the
 * glyph sits beside it (MessageComposer.vue: 24px glyph, chip width + 6,
 * both chip width + 26). On the phone dock a chip text-indents the first
 * line, and a glyph adds its 24px of padding on top of that indent.
 * @param {{ glyph?: boolean, chip?: boolean, chipWidth?: number, phone?: boolean }} [s]
 * @returns {number}
 */
export function omniboxOneLinePad(s = {}) {
  const glyph = Boolean(s.glyph)
  const chip = Boolean(s.chip)
  const w = typeof s.chipWidth === 'number' && s.chipWidth > 0 ? s.chipWidth : 0
  if (!glyph && !chip) return 0
  if (s.phone) {
    if (glyph && chip) return 24 + w + 6
    if (chip) return w + 6
    return 24
  }
  if (glyph && chip) return w + 26
  if (chip) return w + 6
  return 24
}

/**
 * The draft occupies more than one line of the omnibox.
 * A newline (Shift+Enter or a paste) is enough. A wrap is the measured
 * width of that single line against the one-line content box. Widths are
 * optional: without them only a newline counts, so a caller that has not
 * measured yet does not guess.
 * @param {{ text?: string, textWidth?: number, contentWidth?: number }} [s]
 * @returns {boolean}
 */
export function omniboxIsMultiline(s = {}) {
  const text = typeof s.text === 'string' ? s.text : ''
  if (/[\r\n]/.test(text)) return true
  const w = s.textWidth
  const box = s.contentWidth
  if (typeof w !== 'number' || typeof box !== 'number') return false
  if (!(box > 0) || !Number.isFinite(w) || !Number.isFinite(box)) return false
  return w > box + 0.5
}
