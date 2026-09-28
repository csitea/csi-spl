/**
 * Resizable columns of the /issues sheet (owner, topic beb4024f: "the columns
 * of the issues grid should be resizeable").
 *
 * A header's trailing edge is a grip: drag it, or focus it and press
 * ArrowLeft / ArrowRight (or Alt+ArrowLeft / Alt+ArrowRight on the header's
 * sort button); a double-click fits the column to its content, Delete gives
 * it back its automatic width. Widths are a per-browser convenience (localStorage), like
 * the folded status groups - not an account setting. A column without a
 * stored width keeps the sheet's automatic layout exactly as before.
 */
import { storageGetJson, storageSetJson } from './prefs.mjs'

export const ISSUES_COLW_KEY = 'spool.issues.colw'
/** the sheet's resizable columns, in their order */
export const ISSUES_COLW_COLS = ['key', 'title', 'status', 'priority', 'level', 'assignee', 'label', 'deadline', 'updated']
export const COLW_MIN = 48
/** Key and Title must stay usable: their own floor (Title's is its 10rem cell floor) */
export const COLW_MIN_BY_COL = { key: 56, title: 160 }
export const colMin = (col) => COLW_MIN_BY_COL[col] || COLW_MIN
export const COLW_MAX = 960
/** one ArrowLeft / ArrowRight on a focused grip */
export const COLW_STEP = 16

/** A width in whole px inside [the column's minimum, COLW_MAX]; NaN / junk -> null. */
export function clampColWidth(px, col) {
  const n = Number(px)
  if (px == null || px === '' || !Number.isFinite(n)) return null
  return Math.min(COLW_MAX, Math.max(colMin(col), Math.round(n)))
}

/** Only known columns with a usable width survive (a stale or hand-edited entry is dropped). */
export function cleanColWidths(raw) {
  const out = {}
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return out
  for (const col of ISSUES_COLW_COLS) {
    if (raw[col] == null) continue
    const w = clampColWidth(raw[col], col)
    if (w != null) out[col] = w
  }
  return out
}

export function loadColWidths(store) {
  return cleanColWidths(storageGetJson(ISSUES_COLW_KEY, {}, store))
}

export function saveColWidths(widths, store) {
  return storageSetJson(ISSUES_COLW_KEY, cleanColWidths(widths), store)
}

/** The width while dragging: start width + the pointer's travel (mirrored right-to-left). */
export function dragWidth(startPx, dx, rtl = false, col) {
  return clampColWidth(Number(startPx) + (rtl ? -1 : 1) * Number(dx), col)
}

/**
 * A key on a focused grip: the new width, 0 for "back to automatic"
 * (Delete / Backspace), or null when the key does nothing.
 */
export function keyWidth(currentPx, key, rtl = false, col) {
  if (key === 'Delete' || key === 'Backspace') return 0
  const grow = rtl ? 'ArrowLeft' : 'ArrowRight'
  const shrink = rtl ? 'ArrowRight' : 'ArrowLeft'
  if (key === grow) return clampColWidth(Number(currentPx) + COLW_STEP, col)
  if (key === shrink) return clampColWidth(Number(currentPx) - COLW_STEP, col)
  return null
}

/** One column set (px) or back to automatic (0 / null): a NEW object. */
export function withColWidth(widths, col, px) {
  const next = { ...cleanColWidths(widths) }
  const w = px ? clampColWidth(px, col) : null
  if (w == null) delete next[col]
  else if (ISSUES_COLW_COLS.includes(col)) next[col] = w
  return next
}

/** The table's custom properties: --iw-<col> for each set column. */
export function colWidthVars(widths) {
  const out = {}
  for (const [col, w] of Object.entries(cleanColWidths(widths))) out['--iw-' + col] = w + 'px'
  return out
}

/** The table's classes: issues-w-<col> for each set column (clips that column's cells). */
export function colWidthClasses(widths) {
  return Object.keys(cleanColWidths(widths)).map((col) => 'issues-w-' + col)
}
