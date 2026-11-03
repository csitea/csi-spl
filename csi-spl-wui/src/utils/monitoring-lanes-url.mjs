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
 * Only the Lanes page imports this file (C20: not in the initial JS).
 */

import { LANE_AGES, LANE_COLUMNS, LANES_NO_FILTER } from './monitoring-lanes.mjs'

/** The parameters this file owns, in the order they are written. */
export const LANES_URL_PARAMS = ['sort', 'dir', 'box', 'vendor', 'state', 'age', 'workspace', 'text']

/** The filters whose value must be one of the answer's choices. */
const CHOICE_FILTERS = ['box', 'vendor', 'state', 'workspace']
/** A box, vendor, state or workspace id as the hub writes one; anything else is not named. */
const TOKEN_RE = /^[A-Za-z0-9][A-Za-z0-9._:@-]{0,63}$/
const TEXT_MAX = 200

const one = (v) => {
  const raw = Array.isArray(v) ? v[0] : v
  return typeof raw === 'string' ? raw.trim() : ''
}
const token = (v) => (TOKEN_RE.test(v) ? v : '')

/**
 * A route query as the list's sort and filters. A sort needs a sortable
 * column and asc or desc; the age one of LANE_AGES; the text at most 200
 * characters, kept as typed.
 * @param {Record<string, unknown>} [q]
 * @returns {{ sort: { col: string, dir: string }, filters: { text: string, box: string, vendor: string, state: string, age: string, workspace: string } }}
 */
export function lanesStateFromQuery(q = {}) {
  const col = one(q.sort)
  const dir = one(q.dir)
  const sort = LANE_COLUMNS.includes(col) && (dir === 'asc' || dir === 'desc') ? { col, dir } : { col: '', dir: '' }
  /* the text as typed, spaces kept: the address follows each keystroke */
  const rawText = Array.isArray(q.text) ? q.text[0] : q.text
  const text = typeof rawText === 'string' && rawText.trim() && rawText.length <= TEXT_MAX ? rawText : ''
  const age = one(q.age)
  return {
    sort,
    filters: {
      ...LANES_NO_FILTER,
      box: token(one(q.box)),
      vendor: token(one(q.vendor)),
      state: token(one(q.state)),
      workspace: token(one(q.workspace)),
      age: LANE_AGES.includes(age) ? age : '',
      text,
    },
  }
}

/**
 * The query for that state over `base`: this file's parameters replaced,
 * every other one kept.
 * @param {{ sort: { col: string, dir: string }, filters: Record<string, string> }} s
 * @param {Record<string, string>} [base]
 * @returns {Record<string, string>}
 */
export function lanesStateQuery(s, base = {}) {
  /** @type {Record<string, string>} */
  const q = { ...base }
  for (const k of LANES_URL_PARAMS) delete q[k]
  if (s.sort && s.sort.col && s.sort.dir) { q.sort = s.sort.col; q.dir = s.sort.dir }
  for (const k of LANES_URL_PARAMS.slice(2)) {
    const v = String(s.filters[k] || '')
    if (v.trim()) q[k] = v
  }
  return q
}

/**
 * The filters with each box, vendor, state or workspace the answer does not
 * offer set back to All (spec 153 3.15). A link carries the filters of who
 * made it: a member reads the workspace route, which sends no box, so a
 * box from an operator's link would otherwise show a false empty list.
 * @template {Record<string, string>} F
 * @param {F} f
 * @param {{ box: string[], vendor: string[], state: string[], workspace: { id: string }[] }} choices
 * @returns {F}
 */
export function lanesFiltersOffered(f, choices) {
  /** @type {Record<string, string>} */
  const out = { ...f }
  for (const k of CHOICE_FILTERS) {
    const offered = k === 'workspace' ? choices.workspace.map((w) => w.id) : choices[k]
    if (out[k] && !offered.includes(out[k])) out[k] = ''
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
export function sameLanesQuery(a, b) {
  const flat = (/** @type {Record<string, string>} */ q) => JSON.stringify(Object.keys(q).sort().map((k) => [k, String(q[k])]))
  return flat(a) === flat(b)
}
