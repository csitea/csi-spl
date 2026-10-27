// csi-spl-wui/src/utils/reporting-costs.mjs
//
// Spec 143 costs-redesign.md 3.2 and 5, slice S1 (SPL-3798, owner HUM-10,
// t1 1be0e370, msg 3f1c7128, answers 2 A and 6 A): Reporting -> Costs, one
// tab with four pages, each its own path and chunk; the header's one month
// and one currency, carried in the query so every page and the back button
// keep them; the old links that land here. One list for the page bar
// (pages/reporting/costs.vue) and the tests. No costs code here: the Spend
// page alone loads utils/tenant-costs.mjs.

import { productPath } from './signed-out-redirect.mjs'

/** The pages in their order; Spend is where /reporting/costs lands.
 *  `operatorsOnly`: drawn for an operator admin only (the hub's 403 is the control). */
export const COSTS_PAGES = Object.freeze([
  Object.freeze({ id: 'spend', path: '/reporting/costs/spend', labelKey: 'reporting.costs.page.spend', operatorsOnly: false }),
  Object.freeze({ id: 'tokens', path: '/reporting/costs/tokens', labelKey: 'reporting.costs.page.tokens', operatorsOnly: false }),
  Object.freeze({ id: 'price', path: '/reporting/costs/price', labelKey: 'reporting.costs.page.price', operatorsOnly: true }),
  Object.freeze({ id: 'paid', path: '/reporting/costs/paid', labelKey: 'reporting.costs.page.paid', operatorsOnly: true }),
])

export const COSTS_DEFAULT_PATH = COSTS_PAGES[0].path

/** The pages the bar draws for this reader. @param {{ operator?: boolean }} [who] */
export function visibleCostsPages(who = {}) {
  return COSTS_PAGES.filter((p) => !p.operatorsOnly || who.operator === true)
}

/** The page a route is on, locale prefix or not; null off the four pages. @param {string} path */
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
  '/monitoring/costs': '/reporting/costs/spend',
  '/reporting/tokens': '/reporting/costs/tokens',
  '/reporting/costs': '/reporting/costs/spend',
})

/** The Costs page an old link lands on, with or without a locale prefix or a
 *  trailing slash; anything else null (`/monitoring/tokens` stays: live burn).
 * @param {string} path
 */
export function legacyCostsPath(path) {
  const p = productPath(path).replace(/(.)\/+$/, '$1')
  return Object.prototype.hasOwnProperty.call(COSTS_REDIRECTS, p) ? COSTS_REDIRECTS[p] : null
}

/** The first month holding a cost line (costs-redesign.md section 2 item 13:
 *  cost lines start in October 2026); the picker offers nothing before it. */
export const COSTS_FIRST_MONTH = '2026-10'
/** At most this many months in the picker (rule 3.1.2). */
const COSTS_MONTHS_MAX = 12
const MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])$/

/** A valid YYYY-MM (the first of an array query), else ''. */
export function costsMonth(v) {
  const s = Array.isArray(v) ? v[0] : v
  return typeof s === 'string' && MONTH_RE.test(s) ? s : ''
}

const monthOf = (d) => d.toISOString().slice(0, 7)

/**
 * The picker's months, the current UTC month first, back to `first`, at most
 * 12. A `keep` month from the URL (an old link, a bookmark) before `first`
 * but not in the future is added last, so the page shows what the link asked
 * for and never rewrites it.
 * @param {Date} [now]
 * @param {string} [first]
 * @param {string} [keep]
 */
export function costsMonthOptions(now = new Date(), first = COSTS_FIRST_MONTH, keep = '') {
  const out = []
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1))
  while (out.length < COSTS_MONTHS_MAX && monthOf(d) >= first) {
    out.push(monthOf(d))
    d.setUTCMonth(d.getUTCMonth() - 1)
  }
  if (!out.length) out.push(monthOf(now))
  const k = costsMonth(keep)
  if (k && k <= out[0] && !out.includes(k)) out.push(k)
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
 * The query after a header pick: `month` dropped for the current month,
 * `currency` dropped for USD, every other key kept.
 * @param {Record<string, unknown>} query
 * @param {{ month?: string, currency?: string, current?: string }} pick
 */
export function costsQueryWith(query, { month, currency, current } = {}) {
  const q = { ...query }
  if (month !== undefined) {
    if (!costsMonth(month) || month === current) delete q.month
    else q.month = month
  }
  if (currency !== undefined) {
    if (!currency || currency === COSTS_CURRENCY_DEFAULT) delete q.currency
    else q.currency = currency
  }
  return q
}
