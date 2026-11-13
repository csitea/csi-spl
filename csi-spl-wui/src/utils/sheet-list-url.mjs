/**
 * What a column sheet's address says about its sort and filter row, and
 * back, for the Monitoring lists that sort and filter the rows they hold:
 * Lanes (SPL-4729, spec 153 3.15; utils/monitoring-lanes-url.mjs) and
 * Topics (SPL-5430, spec 153 3.29; owner HUM-10, t1 5804c44c, msg b65c7989:
 * "it should behave the same way"). One codec, built per sheet from its
 * columns, so both lists read and write their links the same way.
 *
 * A default (no sort, a filter on All, no text) writes no parameter. A value
 * the page cannot use reads as not named, so a bad link never blanks the
 * page or raises an error. Each column's filter is its own parameter, named
 * as the column; any parameter the codec does not own passes through.
 *
 * Only lazily loaded pages import this file (C20: not in the initial JS).
 * Node tests import it.
 */

/** A box, vendor, state, channel or workspace id as the hub writes one; anything else is not named. */
const TOKEN_RE = /^[A-Za-z0-9][A-Za-z0-9._:@-]{0,63}$/
const TEXT_MAX = 200

const one = (v) => {
  const raw = Array.isArray(v) ? v[0] : v
  return typeof raw === 'string' ? raw.trim() : ''
}
const token = (v) => (TOKEN_RE.test(v) ? v : '')

/** A text filter as typed, spaces kept (the address follows each keystroke), at most 200 characters. */
const typed = (v) => {
  const raw = Array.isArray(v) ? v[0] : v
  return typeof raw === 'string' && raw.trim() && raw.length <= TEXT_MAX ? raw : ''
}

/**
 * @typedef {{ col: string, kind: 'text' | 'choice' }} UrlColumn
 * @typedef {{ sort: { col: string, dir: string }, filters: Record<string, string> }} SheetState
 * @typedef {{
 *   columns: readonly UrlColumn[],
 *   ageColumns: readonly string[],
 *   ages: readonly string[],
 *   noFilter: Readonly<Record<string, string>>,
 *   legacyParams?: readonly string[],
 *   legacyAge?: Record<string, string>,
 * }} SheetUrlSpec
 */

/**
 * A route query as the list's sort and filters. A sort needs a sortable
 * column and asc or desc; an age column one of `ages` (else, for an old
 * link, its `legacyAge` parameter); a choice a token; a text at most 200
 * characters, kept as typed.
 * @param {SheetUrlSpec} spec
 * @param {Record<string, unknown>} [q]
 * @returns {SheetState}
 */
export function sheetStateFromQuery(spec, q = {}) {
  const col = one(q.sort)
  const dir = one(q.dir)
  const known = spec.columns.some((c) => c.col === col)
  const sort = known && (dir === 'asc' || dir === 'desc') ? { col, dir } : { col: '', dir: '' }
  const legacyAge = spec.legacyAge || {}
  /** @type {Record<string, string>} */
  const filters = { ...spec.noFilter }
  for (const c of spec.columns) {
    if (spec.ageColumns.includes(c.col)) {
      const age = one(q[c.col]) || (legacyAge[c.col] ? one(q[legacyAge[c.col]]) : '')
      filters[c.col] = spec.ages.includes(age) ? age : ''
    } else filters[c.col] = c.kind === 'choice' ? token(one(q[c.col])) : typed(q[c.col])
  }
  return { sort, filters }
}

/** The parameters a sheet owns, in the order they are written (an old link's last, never written). */
export function sheetUrlParams(spec) {
  return ['sort', 'dir', ...spec.columns.map((c) => c.col), ...(spec.legacyParams || [])]
}

/**
 * The query for that state over `base`: the sheet's parameters replaced,
 * every other one kept.
 * @param {SheetUrlSpec} spec
 * @param {SheetState} s
 * @param {Record<string, string>} [base]
 * @returns {Record<string, string>}
 */
export function sheetStateQuery(spec, s, base = {}) {
  /** @type {Record<string, string>} */
  const q = { ...base }
  for (const k of sheetUrlParams(spec)) delete q[k]
  if (s.sort && s.sort.col && s.sort.dir) { q.sort = s.sort.col; q.dir = s.sort.dir }
  for (const c of spec.columns) {
    const v = String(s.filters[c.col] || '')
    if (v.trim()) q[c.col] = v
  }
  return q
}

/**
 * The filters with each choice the answer does not offer set back to All
 * (spec 153 3.15): a link carries the filters of who made it. A choice list
 * holds strings or { id } objects (the workspaces); an age column, and a
 * column with no list in `choices`, is left as it is.
 * @template {Record<string, string>} F
 * @param {SheetUrlSpec} spec
 * @param {F} f
 * @param {Record<string, unknown>} choices
 * @returns {F}
 */
export function sheetFiltersOffered(spec, f, choices) {
  /** @type {Record<string, string>} */
  const out = { ...f }
  for (const c of spec.columns) {
    const list = c.kind === 'choice' && !spec.ageColumns.includes(c.col) ? choices[c.col] : null
    if (!Array.isArray(list) || !out[c.col]) continue
    const ids = list.map((v) => (typeof v === 'string' ? v : v.id))
    if (!ids.includes(out[c.col])) out[c.col] = ''
  }
  return /** @type {F} */ (out)
}

/**
 * A route query as plain strings (the first of a repeated key).
 * @param {Record<string, unknown>} [q]
 * @returns {Record<string, string>}
 */
export function plainQuery(q = {}) {
  /** @type {Record<string, string>} */
  const out = {}
  for (const [k, v] of Object.entries(q)) {
    const raw = Array.isArray(v) ? v[0] : v
    if (typeof raw === 'string') out[k] = raw
  }
  return out
}

/**
 * Whether two queries name the same parameters and values, in any order.
 * @param {Record<string, string>} a
 * @param {Record<string, string>} b
 */
export function sameQuery(a, b) {
  const flat = (/** @type {Record<string, string>} */ q) => JSON.stringify(Object.keys(q).sort().map((k) => [k, String(q[k])]))
  return flat(a) === flat(b)
}
