// csi-spl-wui/src/utils/reporting-incomes.mjs
//
// SPL-4697 (spec 143 incomes.md; owner HUM-10, csitea topic 450418ab, msg
// e793f8d0): the Reporting Incomes tab's read, its month rows and its year
// totals. GET /v1/reporting/incomes?year=YYYY answers { year, years,
// invoices }, or 403 to anyone but the workspace's owner. Analytics only
// (incomes.md 0): the page reads, it never writes.

import { mockMeGet, mockRefused } from './act-as-mock.mjs'
import { HUB_READ_TIMEOUT_MS } from './fetch-timeouts.mjs'
import { withSessionRetry } from './live-follow.mjs'

const INCOMES_REPORT_PATH = '/v1/reporting/incomes'

/**
 * @typedef {{ invoice_no: string, payer: string, period: string, issue_date: string, due_date: string,
 *   hours: number, unit_price: number, net: number, vat_pct: number, vat: number, total: number, currency: string }} Invoice
 * @typedef {{ year: number, years: number[], invoices: Invoice[] }} IncomesReport
 */

/**
 * The mock hub's answer: two synthetic invoices of the asked year (none in
 * March, so the gap shows); 403 for a mock role that is not the owner
 * (spool.mock.me; none set plays the owner).
 * @param {number | undefined} year
 * @param {Storage | null} [store]
 * @returns {IncomesReport}
 */
export function mockIncomesReport(year, store) {
  const me = mockMeGet(store)
  if (me && me.role !== 'biz_owner') {
    throw mockRefused(INCOMES_REPORT_PATH, Object.assign(new Error('only the workspace owner sees its incomes'), { status: 403 }))
  }
  const y = year || 2025
  const inv = (no, m, hours) => ({ invoice_no: no, payer: 'ACME', period: `${y}-${m}`, issue_date: `${y}-${m}-28`, due_date: `${y}-${m}-28`,
    hours, unit_price: 125, net: hours * 125, vat_pct: 25, vat: hours * 31.25, total: hours * 156.25, currency: 'EUR' })
  return { year: y, years: [2025, 2024], invoices: y === 2025 ? [inv('INV-0001', '01', 100), inv('INV-0002', '02', 80)] : [] }
}

/**
 * One GET of the year (none = the hub's choice: the newest year with rows).
 * Throws { status } on a non-2xx answer.
 * @param {{ mock?: boolean, base?: string, token?: string, credentials?: RequestCredentials }} api
 * @param {number} [year]
 * @returns {Promise<IncomesReport>}
 */
export function incomesReportRead(api, year) {
  if (api.mock) return Promise.resolve().then(() => mockIncomesReport(year))
  return withSessionRetry(api, async () => {
    const headers = { accept: 'application/json' }
    if (api.token) headers.authorization = `Bearer ${api.token}`
    const q = year ? `?year=${encodeURIComponent(String(year))}` : ''
    const r = await fetch(`${api.base}${INCOMES_REPORT_PATH}${q}`, { credentials: api.credentials, headers, signal: AbortSignal.timeout(HUB_READ_TIMEOUT_MS) })
    if (!r.ok) throw Object.assign(new Error(`incomes report ${r.status}`), { status: r.status })
    return r.json()
  })
}

/**
 * Twelve rows, January first: each month's invoices (a month may hold more
 * than one, or none: `invoices` is then empty and the page draws a dash,
 * never a zero, so a missing invoice shows).
 * @param {Partial<IncomesReport> | undefined} report
 * @returns {{ month: string, invoices: Invoice[] }[]}
 */
export function incomeMonthRows(report) {
  const year = Number(report?.year)
  const list = Array.isArray(report?.invoices) ? report.invoices : []
  return Array.from({ length: 12 }, (_, i) => {
    const month = `${year}-${String(i + 1).padStart(2, '0')}`
    return { month, invoices: list.filter((inv) => inv?.period === month) }
  })
}

/** cents of an amount, so sums never drift */
const cents = (v) => Math.round(Number(v || 0) * 100)

/**
 * The year totals, one per currency in first-seen order (no FX on this
 * tab, incomes.md 1): hours, net, VAT and total summed in cents.
 * @param {Partial<IncomesReport> | undefined} report
 * @returns {{ currency: string, count: number, hours: number, net: number, vat: number, total: number }[]}
 */
export function incomeYearTotals(report) {
  const list = Array.isArray(report?.invoices) ? report.invoices : []
  /** @type {Map<string, { currency: string, count: number, hours: number, net: number, vat: number, total: number }>} */
  const by = new Map()
  for (const inv of list) {
    const t = by.get(inv.currency) || { currency: inv.currency, count: 0, hours: 0, net: 0, vat: 0, total: 0 }
    t.count++
    t.hours += cents(inv.hours)
    t.net += cents(inv.net)
    t.vat += cents(inv.vat)
    t.total += cents(inv.total)
    by.set(inv.currency, t)
  }
  return [...by.values()].map((t) => ({ ...t, hours: t.hours / 100, net: t.net / 100, vat: t.vat / 100, total: t.total / 100 }))
}

/**
 * An amount in the reader's locale with its currency, two decimals.
 * @param {number} v
 * @param {string} currency
 * @param {string} [locale]
 */
export function formatIncomeAmount(v, currency, locale) {
  try {
    return new Intl.NumberFormat(locale, { style: 'currency', currency, minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(v)
  } catch {
    return `${Number(v).toFixed(2)} ${currency}`
  }
}
