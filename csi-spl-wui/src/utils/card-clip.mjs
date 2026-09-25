/** Level-1 card height in the middle pane (CLE-34989, specs/033 FR-020..FR-026).
 *
 *  Owner, 2026-09-25: "clip the size of the msg with is_parent=1 to max 5 rows
 *  of text or max 30% of the screen if picture is involved ... the rest should
 *  be expandable via the similar expandable draggable handle which exists in
 *  the omnibox ... There should be a control which sets the height of those
 *  posts to 3 different ways - only titles (where title is the first 90 chars),
 *  this default of 5 rows max and all size".
 *
 *  Three modes, per browser (prefs.mjs, try/catch):
 *    titles — the first 90 chars of the body on one line, no attachments;
 *    rows   — (default) the body clipped at 5 text rows, or at 30% of the
 *             window when the card carries a picture; a grip drags it taller;
 *    full   — nothing clipped (the card as it was before this change).
 *  The right (thread) pane is never clipped: the host simply does not ask.
 */
import { storageGet, storageSet } from './prefs.mjs'
import { isPreviewableImage } from './file-preview.mjs'

export const CARD_CLIP_KEY = 'spool-card-clip'
export const CARD_CLIP_MODES = Object.freeze(['titles', 'rows', 'full'])
export const CARD_CLIP_DEFAULT = 'rows'
/** Text rows a level-1 card shows in the default mode. */
export const CARD_CLIP_ROWS = 5
/** Share of the window a card with a picture may take in the default mode. */
export const CARD_CLIP_PICTURE_SHARE = 0.3
/** Characters of the body that make a card's title. */
export const CARD_TITLE_CHARS = 90
/** One keyboard step of the grip (ArrowDown / ArrowUp), in rows. */
export const CARD_GRIP_STEP_ROWS = 2

/** A mode from anything (storage string, prop); else `fallback`. */
export function parseCardClipMode(raw, fallback = CARD_CLIP_DEFAULT) {
  const s = String(raw ?? '').trim()
  return CARD_CLIP_MODES.includes(s) ? s : fallback
}

export function readCardClipMode(store) {
  return parseCardClipMode(storageGet(CARD_CLIP_KEY, null, store))
}

export function writeCardClipMode(mode, store) {
  return storageSet(CARD_CLIP_KEY, parseCardClipMode(mode), store)
}

/**
 * The title of a card: the first 90 characters of its body, on one line.
 * Whitespace runs (newlines included) fold to one space, and a ``` fence
 * marker is dropped, so a card that opens with a code block still reads.
 * A cut title ends in an ellipsis; the 90 counts code points, not UTF-16
 * units, so an emoji is never split in half.
 */
export function cardTitle(body, max = CARD_TITLE_CHARS) {
  const flat = String(body ?? '')
    .replace(/```[^\s`]*/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  const chars = Array.from(flat)
  if (chars.length <= max) return flat
  return chars.slice(0, max).join('').trimEnd() + '…'
}

/** True when one of the card's files shows as an inline picture. */
export function cardHasPicture(files) {
  if (!Array.isArray(files)) return false
  return files.some((f) => f && isPreviewableImage(f.name, f.bytes))
}

/**
 * The clip height of a card body in px, or null for "not clipped".
 * @param {{ mode: string, picture: boolean, lineHeightPx: number, viewportPx: number, userPx?: number | null }} s
 *   `userPx` is a grip drag on this card; it replaces the automatic height
 *   (taller or shorter), and is never below one text row.
 * @returns {number | null}
 */
export function cardClipPx(s) {
  const mode = parseCardClipMode(s.mode)
  if (mode !== 'rows') return null
  const line = Math.max(1, Number(s.lineHeightPx) || 0)
  if (typeof s.userPx === 'number' && Number.isFinite(s.userPx)) {
    return Math.max(Math.round(line), Math.round(s.userPx))
  }
  if (s.picture) {
    const vp = Math.max(0, Number(s.viewportPx) || 0)
    return Math.max(Math.round(line * CARD_CLIP_ROWS), Math.round(vp * CARD_CLIP_PICTURE_SHARE))
  }
  return Math.round(line * CARD_CLIP_ROWS)
}

/** The height a grip drag asks for: start + pointer travel, from one row to `maxPx`. */
export function cardDragPx(startPx, dy, lineHeightPx, maxPx) {
  const min = Math.max(1, Math.round(Number(lineHeightPx) || 1))
  const max = Math.max(min, Math.round(Number(maxPx) || min))
  return Math.min(max, Math.max(min, Math.round(Number(startPx) + Number(dy))))
}

/** Clipped when the content is taller than the box (1px of rounding slack). */
export function cardIsClipped(scrollPx, clientPx) {
  return Number(scrollPx) > Number(clientPx) + 1
}
