// Sort and filter for the personal event log. The page already holds the
// rows; nothing here calls the hub. SPL-3366.

/** @typedef {{ col: string, dir: string }} EventSort */
/** @typedef {{ when: string, id: string, source: string, status: string, message: string, route: string }} EventFilters */

export const EVENT_COLUMNS = [
  { col: 'when', key: 'events.col_when', kind: 'text' },
  { col: 'id', key: 'events.col_id', kind: 'text' },
  { col: 'source', key: 'events.col_source', kind: 'choice' },
  { col: 'status', key: 'events.col_status', kind: 'choice' },
  { col: 'message', key: 'events.col_message', kind: 'text' },
  { col: 'route', key: 'events.col_route', kind: 'text' },
]

const FILTER_KEYS = ['when', 'id', 'source', 'status', 'message', 'route']

/** @returns {EventSort} */
export function emptyEventSort() {
  return { col: '', dir: '' }
}

/** @returns {EventFilters} */
export function emptyEventFilters() {
  return { when: '', id: '', source: '', status: '', message: '', route: '' }
}

function knownColumn(col) {
  return EVENT_COLUMNS.some((c) => c.col === col)
}

/** A header click: none → asc → desc → none. A new column starts at asc. */
export function nextEventSort(col, cur) {
  if (!knownColumn(col)) return emptyEventSort()
  if (!cur || cur.col !== col) return { col, dir: 'asc' }
  if (cur.dir === 'asc') return { col, dir: 'desc' }
  return emptyEventSort()
}

/** When uses the date words. Every other column, including status, uses the text words. */
export function eventSortDirKey(col, dir) {
  const date = col === 'when'
  if (dir === 'desc') return date ? 'issues_mobile.dir_date_desc' : 'issues_mobile.dir_text_desc'
  return date ? 'issues_mobile.dir_date_asc' : 'issues_mobile.dir_text_asc'
}

function columnKey(col) {
  const hit = EVENT_COLUMNS.find((c) => c.col === col)
  return hit ? hit.key : 'events.col_when'
}

/** Default (no column selected) still reads as When, newest first. */
export function eventSortLabel(sort) {
  const active = !!(sort && sort.col && (sort.dir === 'asc' || sort.dir === 'desc'))
  if (!active) {
    return { colKey: 'events.col_when', dirKey: 'issues_mobile.dir_date_desc', active: false }
  }
  return { colKey: columnKey(sort.col), dirKey: eventSortDirKey(sort.col, sort.dir), active: true }
}

/** Milliseconds of at, else received_at. Missing or unparseable is 0. */
function eventInstant(row) {
  const raw = (row && (row.at || row.received_at)) || ''
  const n = Date.parse(raw)
  return Number.isFinite(n) ? n : 0
}

function textOf(row, col) {
  if (!row) return ''
  if (col === 'id') return String(row.error_id || '')
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
  if (!filters) return false
  return FILTER_KEYS.some((key) => String(filters[key] || '').trim() !== '')
}

function contains(hay, needle) {
  return String(hay || '').toLowerCase().includes(needle)
}

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

function rowMatches(row, filters, pinId) {
  if (pinId && row && String(row.id) === String(pinId)) return true
  if (!filtersActive(filters)) return true
  const when = String(filters.when || '').trim().toLowerCase()
  const id = String(filters.id || '').trim().toLowerCase()
  const source = String(filters.source || '').trim()
  const status = String(filters.status || '').trim()
  const message = String(filters.message || '').trim().toLowerCase()
  const route = String(filters.route || '').trim().toLowerCase()
  if (when && !whenMatches(row, when)) return false
  if (id && !contains(row && row.error_id, id)) return false
  if (source && String((row && row.source) || '').trim() !== source) return false
  if (status !== '' && String(row && row.status) !== status) return false
  if (message && !contains(row && row.message, message)) return false
  if (route && !contains(row && row.route, route)) return false
  return true
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
  const list = Array.isArray(rows) ? rows : []
  const seen = new Set()
  for (const row of list) {
    const value = choiceValue(row, field)
    if (value !== '') seen.add(value)
  }
  const out = [...seen]
  out.sort(field === 'status' ? cmpNumStr : (a, b) => cmpText(a, b))
  return out
}

/** Filter, then sort. `pinId` stays in the list even when the filter would hide it. */
export function applyEventSheet(rows, opts) {
  const o = opts || {}
  return sortEvents(filterEvents(rows, o.filters, o.pinId), o.sort)
}
