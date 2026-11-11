// Sort and filter for the personal event log. The page already holds the
// rows; nothing here calls the hub. SPL-3366. Spec 162 B1 (E1): the
// request (METHOD path) and code (code, then name) columns.
// SPL-5276: the column-sheet rules (the sort cycle, the sort words, a text or
// choice filter per column, the present values) live in column-sheet.mjs,
// which Monitoring -> Lanes shares; this file keeps what is the log's own.

import {
  emptySheetFilters,
  emptySheetSort,
  nextSheetSort,
  sheetFiltersActive,
  sheetPresentValues,
  sheetRowMatches,
  sheetSortDirKey,
  sheetSortLabel,
  sheetTextHas,
} from './column-sheet.mjs'

/** @typedef {{ col: string, dir: string }} EventSort */
/** @typedef {{ when: string, id: string, source: string, status: string, request: string, code: string, message: string, route: string }} EventFilters */

export const EVENT_COLUMNS = [
  { col: 'when', key: 'events.col_when', kind: 'text', words: 'date' },
  { col: 'id', key: 'events.col_id', kind: 'text' },
  { col: 'source', key: 'events.col_source', kind: 'choice' },
  { col: 'status', key: 'events.col_status', kind: 'choice' },
  { col: 'request', key: 'events.col_request', kind: 'text' },
  { col: 'code', key: 'events.col_code', kind: 'text' },
  { col: 'message', key: 'events.col_message', kind: 'text' },
  { col: 'route', key: 'events.col_route', kind: 'text' },
]

/** @returns {EventSort} */
export function emptyEventSort() {
  return emptySheetSort()
}

/** @returns {EventFilters} */
export function emptyEventFilters() {
  return /** @type {EventFilters} */ (emptySheetFilters(EVENT_COLUMNS))
}

/** A header click: none → asc → desc → none. A new column starts at asc. */
export function nextEventSort(col, cur) {
  return nextSheetSort(col, cur, EVENT_COLUMNS)
}

/** When uses the date words. Every other column, including status, uses the text words. */
export function eventSortDirKey(col, dir) {
  return sheetSortDirKey(dir, col === 'when' ? 'date' : 'text')
}

/** The log's own order, the label of no sort: When, newest first. */
const EVENT_DEFAULT_SORT = { colKey: 'events.col_when', dirKey: 'issues_mobile.dir_date_desc' }

/** Default (no column selected) still reads as When, newest first. */
export function eventSortLabel(sort) {
  return sheetSortLabel(sort, EVENT_COLUMNS, EVENT_DEFAULT_SORT)
}

/** Milliseconds of at, else received_at. Missing or unparseable is 0. */
function eventInstant(row) {
  const raw = (row && (row.at || row.received_at)) || ''
  const n = Date.parse(raw)
  return Number.isFinite(n) ? n : 0
}

/** The request cell: METHOD path, either one alone when the other is blank. */
export function eventRequestText(row) {
  if (!row) return ''
  return [row.method, row.path].map((x) => String(x || '').trim()).filter(Boolean).join(' ')
}

/** The code cell as one string: code, then name. */
export function eventCodeText(row) {
  if (!row) return ''
  return [row.code, row.name].map((x) => String(x || '').trim()).filter(Boolean).join(' ')
}

function textOf(row, col) {
  if (!row) return ''
  if (col === 'id') return String(row.error_id || '')
  if (col === 'request') return eventRequestText(row)
  if (col === 'code') return eventCodeText(row)
  if (col === 'source') return String(row.source || '')
  if (col === 'message') return String(row.message || '')
  if (col === 'route') return String(row.route || '')
  return ''
}

function statusNum(row) {
  const n = Number(row && row.status)
  return Number.isFinite(n) ? n : 0
}

function cmpText(a, b) {
  return String(a).localeCompare(String(b), undefined, { sensitivity: 'base' })
}

function cmpPrimary(a, b, col) {
  if (col === 'when') return eventInstant(a) - eventInstant(b)
  if (col === 'status') return statusNum(a) - statusNum(b)
  return cmpText(textOf(a, col), textOf(b, col))
}

function cmpTie(a, b) {
  const byTime = eventInstant(b) - eventInstant(a)
  if (byTime) return byTime
  return Number(b && b.id) - Number(a && a.id)
}

/** Newest first when no column is selected. Does not mutate `rows`. */
export function sortEvents(rows, sort) {
  const list = Array.isArray(rows) ? rows.slice() : []
  const col = sort && sort.col
  const dir = sort && sort.dir
  const active = !!(col && (dir === 'asc' || dir === 'desc'))
  const sign = dir === 'desc' ? -1 : 1
  list.sort((a, b) => {
    if (active) {
      const primary = cmpPrimary(a, b, col)
      if (primary) return primary * sign
    }
    return cmpTie(a, b)
  })
  return list
}

/** True when any filter field has text that is not only spaces. */
export function filtersActive(filters) {
  return sheetFiltersActive(filters, EVENT_COLUMNS)
}

const contains = sheetTextHas

function utcDay(row) {
  const n = eventInstant(row)
  if (!n) return ''
  return new Date(n).toISOString().slice(0, 10)
}

function queryDay(q) {
  if (/^\d{4}-\d{2}-\d{2}$/.test(q)) return q
  const parsed = Date.parse(q)
  if (!Number.isFinite(parsed)) return ''
  return new Date(parsed).toISOString().slice(0, 10)
}

function whenMatches(row, q) {
  if (contains(row && row.at, q) || contains(row && row.received_at, q)) return true
  const day = queryDay(q)
  return day !== '' && utcDay(row) === day
}

/* the log's own cells: When reads the time or its UTC day, a status is the
   number as sent; every other column is the shared text or choice rule */
const EVENT_CELLS = {
  textOf,
  choiceOf: (row, col) => String((row && row[col]) || ''),
  custom: (row, col, q) => {
    if (col === 'when') return whenMatches(row, q.toLowerCase())
    if (col === 'status') return String(row && row.status) === q
    return undefined
  },
}

function rowMatches(row, filters, pinId) {
  if (pinId && row && String(row.id) === String(pinId)) return true
  if (!filtersActive(filters)) return true
  return sheetRowMatches(row, filters, EVENT_COLUMNS, EVENT_CELLS)
}

/** Rows that match. pinId stays even when the filter would hide it. */
export function filterEvents(rows, filters, pinId) {
  const list = Array.isArray(rows) ? rows : []
  return list.filter((row) => rowMatches(row, filters, pinId))
}

function choiceValue(row, field) {
  if (!row) return ''
  if (field === 'status') {
    if (row.status === undefined || row.status === null || row.status === '') return ''
    return String(row.status)
  }
  return String(row[field] == null ? '' : row[field]).trim()
}

function cmpNumStr(a, b) {
  return Number(a) - Number(b)
}

/** Values present on the loaded rows. Status is numeric. Blanks are dropped. */
export function presentValues(rows, field) {
  return sheetPresentValues(rows, (row) => choiceValue(row, field), field === 'status' ? cmpNumStr : cmpText)
}

/** Filter, then sort. `pinId` stays in the list even when the filter would hide it. */
export function applyEventSheet(rows, opts) {
  const o = opts || {}
  return sortEvents(filterEvents(rows, o.filters, o.pinId), o.sort)
}
