/**
 * One column-sheet sort and filter for the tables that sort and filter the
 * rows they already hold: the Event log (utils/event-sheet.mjs, SPL-3366) and
 * Monitoring -> Lanes (SPL-5276; owner HUM-10, t1 e1e97af9, msg 7ccb6bfa:
 * "Sorting and filtering in lanes should behave exactly as sorting and
 * filtering for the event log"). The controls that show it are
 * components/SheetHead.vue (the desktop's names and filter row) and
 * components/SheetPhoneBar.vue (the phone's bar and its two sheets).
 *
 * A column is { col, key, kind: 'text' | 'choice', words?: 'date' | 'num' | 'text' }:
 * - a header click cycles none -> ascending -> descending -> none, a new
 *   column starting ascending (utils/sheet-sort.mjs cycleSort);
 * - only the sorted column shows its mark (▲ ascending, ▼ descending);
 * - each column has one filter under its name: a text column keeps the rows
 *   whose cell holds the typed text (any case), a choice column the rows
 *   whose value equals the one picked ('' = All);
 * - the filters combine (every one must match).
 *
 * Node tests import it; only lazily loaded pages do, never the initial JS.
 */

import { cycleSort } from './sheet-sort.mjs'

/** @typedef {{ col: string, dir: string }} SheetSort */
/** @typedef {{ col: string, key: string, kind: 'text' | 'choice', words?: 'date' | 'num' | 'text' }} SheetColumn */

/** @returns {SheetSort} no column sorted: the list's own order */
export function emptySheetSort() {
  return { col: '', dir: '' }
}

/** @param {SheetSort | null | undefined} sort */
function sheetSortActive(sort) {
  return !!(sort && sort.col && (sort.dir === 'asc' || sort.dir === 'desc'))
}

/**
 * A header click over `columns`; an unknown column is the default order.
 * @param {string} col
 * @param {SheetSort | null | undefined} cur
 * @param {readonly SheetColumn[]} columns
 * @returns {SheetSort}
 */
export function nextSheetSort(col, cur, columns) {
  return cycleSort(col, cur || emptySheetSort(), columns.map((c) => c.col))
}

/** The th's aria-sort for a column. */
export function sheetAriaSort(sort, col) {
  if (!sort || sort.col !== col) return 'none'
  if (sort.dir === 'asc') return 'ascending'
  if (sort.dir === 'desc') return 'descending'
  return 'none'
}

/** The mark after a column's name: only the sorted one shows it. */
export function sheetSortMark(sort, col) {
  if (!sort || sort.col !== col) return ''
  if (sort.dir === 'asc') return '▲'
  if (sort.dir === 'desc') return '▼'
  return ''
}

/** The direction's words for a column's kind of value. */
export function sheetSortDirKey(dir, words = 'text') {
  const kind = words === 'date' || words === 'num' ? words : 'text'
  return 'issues_mobile.dir_' + kind + (dir === 'desc' ? '_desc' : '_asc')
}

/**
 * The phone bar's "Sorted: <column>, <direction>" as i18n keys. No sort reads
 * as `fallback`, the list's own order (the Event log's: When, newest first).
 * @param {SheetSort} sort
 * @param {readonly SheetColumn[]} columns
 * @param {{ colKey: string, dirKey: string }} fallback
 */
export function sheetSortLabel(sort, columns, fallback) {
  const hit = sheetSortActive(sort) ? columns.find((c) => c.col === sort.col) : null
  if (!hit) return { colKey: fallback.colKey, dirKey: fallback.dirKey, active: false }
  return { colKey: hit.key, dirKey: sheetSortDirKey(sort.dir, hit.words), active: true }
}

/** @param {readonly SheetColumn[]} columns @returns {Record<string, string>} every filter on All */
export function emptySheetFilters(columns) {
  /** @type {Record<string, string>} */
  const out = {}
  for (const c of columns) out[c.col] = ''
  return out
}

/** True when any column's filter holds more than spaces. */
export function sheetFiltersActive(filters, columns) {
  if (!filters) return false
  return columns.some((c) => String(filters[c.col] || '').trim() !== '')
}

/** A text filter: the cell holds the text, any case (`needle` already lower-cased). */
export function sheetTextHas(hay, needle) {
  return String(hay || '').toLowerCase().includes(needle)
}

/**
 * Whether one row passes every filter. `textOf(row, col)` is a text cell's
 * words; `choiceOf(row, col)` a choice cell's value. A column the caller
 * matches itself (`custom(row, col, query)` returns true or false) skips the
 * rule; it returns undefined for the others.
 * @template T
 * @param {T} row
 * @param {Record<string, string>} filters
 * @param {readonly SheetColumn[]} columns
 * @param {{ textOf: (row: T, col: string) => string, choiceOf: (row: T, col: string) => string,
 *   custom?: (row: T, col: string, query: string) => boolean | undefined }} cells
 */
export function sheetRowMatches(row, filters, columns, cells) {
  for (const c of columns) {
    const raw = String((filters && filters[c.col]) || '').trim()
    if (!raw) continue
    const own = cells.custom ? cells.custom(row, c.col, raw) : undefined
    if (own !== undefined) { if (!own) return false; continue }
    if (c.kind === 'choice') {
      if (String(cells.choiceOf(row, c.col) ?? '').trim() !== raw) return false
    } else if (!sheetTextHas(cells.textOf(row, c.col), raw.toLowerCase())) return false
  }
  return true
}

/**
 * The distinct non-blank values of a choice column on the rows held, sorted
 * (`cmp`, else as words, any case).
 * @template T
 * @param {T[]} rows
 * @param {(row: T) => string} valueOf
 * @param {(a: string, b: string) => number} [cmp]
 */
export function sheetPresentValues(rows, valueOf, cmp) {
  const seen = new Set()
  for (const row of Array.isArray(rows) ? rows : []) {
    const v = String(valueOf(row) ?? '').trim()
    if (v !== '') seen.add(v)
  }
  return [...seen].sort(cmp || ((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' })))
}
