// csi-spl-wui/src/utils/reporting-costs.mjs
//
// Spec 143 costs-redesign.md 3.2 and 5, slice S1 (SPL-3798, owner HUM-10,
// t1 1be0e370, msg 3f1c7128, answers 2 A and 6 A): Reporting -> Costs, one
// tab with its pages, each its own path and chunk; the header's one period
// and one currency, carried in the query so every page and the back button
// keep them; the old links that land here. One list for the page bar
// (pages/reporting/costs.vue) and the tests. No costs code here: the label
// pages load utils/costs-labels.mjs. SPL-4382: the Paid items page left for
// Expenses -> AI costs (utils/expenses-tabs.mjs).
//
// SPL-5312 (spec 143 costs-redesign.md 3.9; owner HUM-10, t1 41a74806,
// 2026-11-11: "there should be only the following labels - Total, Persons,
// Cloud, Tokens" and "a dropdown for the costs for each month for the last
// 12 months and from the start of the year"): the four labels, every one
// for every costs reader (the hub scopes the money to the workspace), and
// the period: each of the last 12 months, or the year to date.

import { productPath } from './signed-out-redirect.mjs'

/** The pages in their order; the first is where /reporting/costs lands.
 *  Spec 123 P05 (SPL-6117; owner HUM-10, t1 e2c0e6b4, msg 3a795cdb, Q-9 A:
 *  "First label and the default ... (five labels, Total second)"): the
 *  project's cost first, then the four labels of SPL-5312.
 *  `operatorsOnly`: drawn for an operator admin only (none since SPL-5312:
 *  a workspace reads its own costs on every label, the hub's scope). */
export const COSTS_PAGES = Object.freeze([
  Object.freeze({ id: 'project', path: '/reporting/costs/project', labelKey: 'reporting.costs.label.project', operatorsOnly: false }),
  Object.freeze({ id: 'total', path: '/reporting/costs/total', labelKey: 'reporting.costs.label.total', operatorsOnly: false }),
  Object.freeze({ id: 'persons', path: '/reporting/costs/persons', labelKey: 'reporting.costs.label.persons', operatorsOnly: false }),
  Object.freeze({ id: 'cloud', path: '/reporting/costs/cloud', labelKey: 'reporting.costs.label.cloud', operatorsOnly: false }),
  Object.freeze({ id: 'tokens', path: '/reporting/costs/tokens', labelKey: 'reporting.costs.label.tokens', operatorsOnly: false }),
])

export const COSTS_DEFAULT_PATH = COSTS_PAGES[0].path

/** The pages the bar draws for this reader. @param {{ operator?: boolean }} [who] */
export function visibleCostsPages(who = {}) {
  return COSTS_PAGES.filter((p) => !p.operatorsOnly || who.operator === true)
}

/** The page a route is on, locale prefix or not; null off the pages. @param {string} path */
export function costsPageFor(path) {
  const p = productPath(path)
  for (const page of COSTS_PAGES) {
    if (p === page.path || p.startsWith(page.path + '/')) return page.id
  }
  return null
}

/** Section 5 "Links": an old path -> its Costs page, no locale prefix (the
 *  caller adds it and keeps the query, `?month=` included). */
export const COSTS_REDIRECTS = Object.freeze({
  '/monitoring/costs': '/reporting/costs/total',
  '/reporting/tokens': '/reporting/costs/tokens',
  '/reporting/costs': COSTS_DEFAULT_PATH,
  /* SPL-5312: the pages before the four labels land on their label; Price
     per token's figures live in Expenses -> AI costs, linked from Tokens */
  '/reporting/costs/spend': '/reporting/costs/total',
  '/reporting/costs/human': '/reporting/costs/persons',
  '/reporting/costs/price': '/reporting/costs/tokens',
  /* SPL-4382 (spec 143 costs-redesign.md 3.8): the paid items are entered
     under Expenses, Costs only reports them */
  '/reporting/costs/paid': '/expenses/ai',
})

/** The Costs page an old link lands on, with or without a locale prefix or a
 *  trailing slash; anything else null (`/monitoring/tokens` stays: live burn).
 * @param {string} path
 */
export function legacyCostsPath(path) {
  const p = productPath(path).replace(/(.)\/+$/, '$1')
  return Object.prototype.hasOwnProperty.call(COSTS_REDIRECTS, p) ? COSTS_REDIRECTS[p] : null
}

/** At most this many months in the picker (SPL-5312: "the last 12 months"). */
const COSTS_MONTHS_MAX = 12
const MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])$/
/** The period "from the start of the year" (SPL-5312), `?month=ytd`. */
export const COSTS_YTD = 'ytd'
/** The period "the last 12 months" (SPL-5433 step b, owner t1 2d974709: "a total
 *  for both the start of the year till now and for the last 12 months"), `?month=l12m`:
 *  the current month so far and the 11 before it. */
export const COSTS_L12M = 'l12m'
/** The preset periods that span months; a range (costsRange) spans too; anything else is one month. */
const COSTS_SPANS = Object.freeze([COSTS_YTD, COSTS_L12M])

/** A valid YYYY-MM (the first of an array query), else ''. */
export function costsMonth(v) {
  const s = Array.isArray(v) ? v[0] : v
  return typeof s === 'string' && MONTH_RE.test(s) ? s : ''
}

const monthOf = (d) => d.toISOString().slice(0, 7)

/**
 * The picker's months, the current UTC month first, then the 11 before it
 * (`n` months: the range pickers take COSTS_RANGE_MAX).
 * A `keep` month from the URL (an old link, a bookmark) older than those but
 * not in the future is added last, so the page shows what the link asked for
 * and never rewrites it.
 * @param {Date} [now]
 * @param {string} [keep]
 * @param {number} [n]
 */
export function costsMonthOptions(now = new Date(), keep = '', n = COSTS_MONTHS_MAX) {
  const out = []
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1))
  while (out.length < n) {
    out.push(monthOf(d))
    d.setUTCMonth(d.getUTCMonth() - 1)
  }
  const k = costsMonth(keep)
  if (k && k <= out[0] && !out.includes(k)) out.push(k)
  return out
}

/** The period a query names: 'ytd', 'l12m', a month not in the future, else '' (the current month). @param {unknown} v @param {Date} [now] */
export function costsPeriod(v, now = new Date()) {
  const s = Array.isArray(v) ? v[0] : v
  if (COSTS_SPANS.includes(s)) return s
  const m = costsMonth(s)
  return m && m <= monthOf(now) ? m : ''
}

/**
 * SPL-6300 (spec 143 costs-redesign.md 3.10; owner HUM-10, workspace topic
 * f3203933 msg 2f3e560e: "from month till month (including) aka start month
 * and end month to calculate all of the costs"): a start month and an end
 * month, both included, `?from=YYYY-MM&to=YYYY-MM`. At most this many
 * months, the hub's own cap (cost_range.go costRangeMaxMonths).
 */
export const COSTS_RANGE_MAX = 24
/** A range period reads `<from>..<to>`. */
const RANGE_SEP = '..'

/** The months from `from` to `to`, both included, oldest first. @param {string} from @param {string} to */
export function costsMonthsBetween(from, to) {
  const out = []
  const d = new Date(Date.UTC(Number(from.slice(0, 4)), Number(from.slice(5, 7)) - 1, 1))
  while (monthOf(d) <= to && out.length <= COSTS_RANGE_MAX) {
    out.push(monthOf(d))
    d.setUTCMonth(d.getUTCMonth() + 1)
  }
  return out
}

/**
 * The range a query names: `from` and `to` both a valid YYYY-MM, from not
 * after to, to not in the future, at most COSTS_RANGE_MAX months; else null
 * (the page then reads `?month=` as before).
 * @param {Record<string, unknown>} query
 * @param {Date} [now]
 */
export function costsRange(query, now = new Date()) {
  const from = costsMonth(query?.from)
  const to = costsMonth(query?.to)
  if (!from || !to || from > to || to > monthOf(now)) return null
  return costsMonthsBetween(from, to).length > COSTS_RANGE_MAX ? null : { from, to }
}

/**
 * The period a whole query names: a range (`<from>..<to>`; one month when
 * from = to), else costsPeriod of `?month=`.
 * @param {Record<string, unknown>} query
 * @param {Date} [now]
 */
export function costsPeriodOf(query, now = new Date()) {
  const r = costsRange(query, now)
  if (r) return r.from === r.to ? r.from : r.from + RANGE_SEP + r.to
  return costsPeriod(query?.month, now)
}

/**
 * The range after one end is picked: the other end follows it when the two
 * would cross, and when they would span more than COSTS_RANGE_MAX months.
 * @param {{ from: string, to: string }} ends the range shown
 * @param {'from' | 'to'} end
 * @param {string} month the month picked
 */
export function costsRangeEnds(ends, end, month) {
  const shift = (m, n) => {
    const d = new Date(Date.UTC(Number(m.slice(0, 4)), Number(m.slice(5, 7)) - 1 + n, 1))
    return monthOf(d)
  }
  if (end === 'from') {
    const last = shift(month, COSTS_RANGE_MAX - 1)
    return { from: month, to: ends.to < month ? month : ends.to > last ? last : ends.to }
  }
  const first = shift(month, 1 - COSTS_RANGE_MAX)
  return { from: ends.from > month ? month : ends.from < first ? first : ends.from, to: month }
}

/** A range period's ends, else null. @param {string} period */
export function costsRangeOf(period) {
  const [from, to] = String(period).split(RANGE_SEP)
  return to !== undefined && costsMonth(from) && costsMonth(to) ? { from, to } : null
}

/**
 * The months a period reads, oldest first: the year to date is January to the
 * current month, the last 12 months the picker's 12, a range its months.
 * @param {string} period
 * @param {Date} [now]
 */
export function costsPeriodMonths(period, now = new Date()) {
  const cur = monthOf(now)
  const r = costsRangeOf(period)
  if (r) return costsMonthsBetween(r.from, r.to)
  if (period === COSTS_L12M) return costsMonthOptions(now).reverse()
  if (period !== COSTS_YTD) return [costsPeriod(period, now) || cur]
  const out = []
  for (let m = 1; m <= now.getUTCMonth() + 1; m++) out.push(cur.slice(0, 5) + String(m).padStart(2, '0'))
  return out
}

/** The default currency (owner answer 2 A). */
const COSTS_CURRENCY_DEFAULT = 'USD'

/** The header's currency choices: USD and the reader's second currency (EUR
 *  unless picked; one choice when it is USD).
 * @param {string} [second]
 */
export function costsCurrencyOptions(second = '') {
  const s = /^[A-Z]{3}$/.test(String(second)) ? String(second) : 'EUR'
  return s === COSTS_CURRENCY_DEFAULT ? [COSTS_CURRENCY_DEFAULT] : [COSTS_CURRENCY_DEFAULT, s]
}

/** The currency the query names when it is one of `options`, else USD. */
export function costsCurrency(v, options) {
  const s = Array.isArray(v) ? v[0] : v
  return typeof s === 'string' && options.includes(s) ? s : COSTS_CURRENCY_DEFAULT
}

/**
 * The query after a header pick: `month` (a month, 'ytd' or 'l12m') dropped for the current month,
 * `currency` dropped for USD, every other key kept. A month pick drops the
 * range; a range pick (`from` and `to`, SPL-6300) drops `month`, and is
 * dropped itself when both are the current month (the default view).
 * @param {Record<string, unknown>} query
 * @param {{ month?: string, currency?: string, current?: string, from?: string, to?: string }} pick
 */
export function costsQueryWith(query, { month, currency, current, from, to } = {}) {
  const q = { ...query }
  if (month !== undefined) {
    delete q.from
    delete q.to
    if ((!costsMonth(month) && !COSTS_SPANS.includes(month)) || month === current) delete q.month
    else q.month = month
  }
  if (from !== undefined && to !== undefined) {
    delete q.month
    delete q.from
    delete q.to
    if (costsMonth(from) && costsMonth(to) && !(from === current && to === current)) Object.assign(q, { from, to })
  }
  if (currency !== undefined) {
    if (!currency || currency === COSTS_CURRENCY_DEFAULT) delete q.currency
    else q.currency = currency
  }
  return q
}
