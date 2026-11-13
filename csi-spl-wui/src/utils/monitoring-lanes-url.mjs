/**
 * SPL-4729 (spec 153 3.15; owner HUM-10, t1 0a730c21, msg ea87c5c1: "the full
 * state of the lanes listing must be shareable via a link - aka once the
 * lanes have been sorted and filtered"): what Monitoring -> Lanes' address
 * says about its sort and filter row, and back. The Issues list's twin is
 * utils/issues-list-url.ts (SPL-4648).
 *
 * A default (no sort, a filter on All, no text) writes no parameter. A value
 * the page cannot use reads as not named, so a bad link never blanks the
 * page or raises an error. `lane` (the deep link, 3.9) and any other
 * parameter pass through untouched.
 *
 * SPL-5276: the filter row is the Event log's, one filter per column, so
 * each column's filter is its own parameter, named as the column. A link of
 * the old row reads as far as it can: `age` is Updated's age; `text` (the
 * box over four columns, gone) is dropped.
 *
 * SPL-5430 (3.29): the codec is utils/sheet-list-url.mjs, shared with
 * Monitoring -> Topics; this file is the Lanes sheet's spec and names.
 *
 * Only the Lanes page imports this file (C20: not in the initial JS).
 */

import { LANE_AGE_COLUMNS, LANE_AGES, LANE_SHEET_COLUMNS, LANES_NO_FILTER } from './monitoring-lanes.mjs'
import { plainQuery, sameQuery, sheetFiltersOffered, sheetStateFromQuery, sheetStateQuery, sheetUrlParams } from './sheet-list-url.mjs'

/** The Lanes sheet's address: its columns, `age` and `text` an old link's (read once, never written). */
export const LANES_URL_SPEC = Object.freeze({
  columns: LANE_SHEET_COLUMNS,
  ageColumns: LANE_AGE_COLUMNS,
  ages: LANE_AGES,
  noFilter: LANES_NO_FILTER,
  legacyParams: ['age', 'text'],
  legacyAge: { updated: 'age' },
})

/** The parameters this file owns, in the order they are written (`age` and `text`: an old link's, read once, never written). */
export const LANES_URL_PARAMS = sheetUrlParams(LANES_URL_SPEC)

/**
 * A route query as the list's sort and filters.
 * @param {Record<string, unknown>} [q]
 * @returns {{ sort: { col: string, dir: string }, filters: Record<string, string> }}
 */
export function lanesStateFromQuery(q = {}) {
  return sheetStateFromQuery(LANES_URL_SPEC, q)
}

/**
 * The query for that state over `base`: this file's parameters replaced,
 * every other one kept.
 * @param {{ sort: { col: string, dir: string }, filters: Record<string, string> }} s
 * @param {Record<string, string>} [base]
 * @returns {Record<string, string>}
 */
export function lanesStateQuery(s, base = {}) {
  return sheetStateQuery(LANES_URL_SPEC, s, base)
}

/**
 * The filters with each box, prio, vendor, state or workspace the answer does not
 * offer set back to All (spec 153 3.15). A link carries the filters of who
 * made it: a member reads the workspace route, which sends no box, so a
 * box from an operator's link would otherwise show a false empty list.
 * @template {Record<string, string>} F
 * @param {F} f
 * @param {{ box: string[], priority: string[], vendor: string[], state: string[], workspace: { id: string }[] }} choices
 * @returns {F}
 */
export function lanesFiltersOffered(f, choices) {
  return sheetFiltersOffered(LANES_URL_SPEC, f, choices)
}

export { plainQuery }

/**
 * Whether two queries name the same parameters and values, in any order.
 * @param {Record<string, string>} a
 * @param {Record<string, string>} b
 */
export function sameLanesQuery(a, b) {
  return sameQuery(a, b)
}
