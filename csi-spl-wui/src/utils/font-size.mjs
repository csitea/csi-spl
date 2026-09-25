/** Font size — five levels, per browser (Settings → Appearance).
 *
 *  One root variable drives it: `html { font-size: var(--font-root) }` and
 *  every text size in the app is rem, so the whole UI follows one attribute,
 *  `data-font-size="<level>"` on <html>. The percentages are of the browser's
 *  own default (16px unless the reader changed it), so a reader who already
 *  raised it in the browser keeps that on top.
 *
 *  Owner, 2026-09-25: the default is a step bigger than it was. Until then the
 *  root was the browser's 100% (16px) — that is level 2 now; the default is 3.
 *
 *  Storage is try/catch via prefs.mjs (private mode).
 */
import { storageGet, storageSet } from './prefs.mjs'

export const FONT_SIZE_KEY = 'spool-font-size'
export const FONT_SIZE_MIN = 1
export const FONT_SIZE_MAX = 5
export const FONT_SIZE_DEFAULT = 3

/** Root font-size per level, % of the browser default (16px → 14/16/18/20/22). */
export const FONT_SIZE_PERCENT = Object.freeze({ 1: 87.5, 2: 100, 3: 112.5, 4: 125, 5: 137.5 })

export const FONT_SIZE_LEVELS = Object.freeze([1, 2, 3, 4, 5])

/** A level 1..5 from anything (string from storage, number); else `fallback`. */
export function parseFontSize(raw, fallback = FONT_SIZE_DEFAULT) {
  const s = String(raw ?? '').trim()
  if (!/^[0-9]+$/.test(s)) return fallback
  const n = Number(s)
  return n >= FONT_SIZE_MIN && n <= FONT_SIZE_MAX ? n : fallback
}

/** One step from `level` (delta -1 = smaller, +1 = bigger), clamped at 1 and 5. */
export function stepFontSize(level, delta) {
  const n = parseFontSize(level) + Math.sign(Number(delta) || 0)
  return Math.min(FONT_SIZE_MAX, Math.max(FONT_SIZE_MIN, n))
}

export function canShrinkFont(level) {
  return parseFontSize(level) > FONT_SIZE_MIN
}

export function canGrowFont(level) {
  return parseFontSize(level) < FONT_SIZE_MAX
}

export function readStoredFontSize(store, fallback = FONT_SIZE_DEFAULT) {
  return parseFontSize(storageGet(FONT_SIZE_KEY, null, store), fallback)
}

export function writeStoredFontSize(level, store) {
  return storageSet(FONT_SIZE_KEY, parseFontSize(level), store)
}

export function applyFontSizeAttr(level, el) {
  const n = parseFontSize(level)
  if (el && typeof el.setAttribute === 'function') el.setAttribute('data-font-size', String(n))
  return n
}
