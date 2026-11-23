/**
 * Spec 181 row B13 (gap G14; Q-17 B, Q-18 C): Monitoring -> Invoices, the
 * owner's overdue list over GET /v1/operator/invoices/overdue and the mark
 * paid over POST /v1/operator/invoices/{id}/{month}/paid (hub
 * internal/hub/operator_invoices.go). A private workspace's monthly invoice
 * is paid by bank transfer; one unpaid past its due date is listed, and the
 * owner decides each case by hand. Nothing here decides anything.
 *
 * Only the Invoices page and the lazy spool client import this file. Node
 * tests import it.
 */

import { mockRefused } from './act-as-mock.mjs'
import { isoSeconds } from './iso-seconds.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from './monitoring-tokens.mjs'

/** e2e opt-in (mock only): the months marked paid, a JSON list of "<workspace>/<month>". */
export const INVOICES_MOCK_PAID_KEY = 'spool.mock.invoices_paid'

const MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])$/
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/
const CUR_RE = /^[A-Z]{3}$/
const str = (v) => (typeof v === 'string' ? v : '')
const int = (v) => (Number.isFinite(Number(v)) && Number(v) >= 0 ? Math.trunc(Number(v)) : 0)

/** The mark paid route of one invoice. */
export function invoicePaidPath(workspace, month) {
  return '/v1/operator/invoices/' + encodeURIComponent(String(workspace || '')) + '/' + encodeURIComponent(String(month || '')) + '/paid'
}

/**
 * The hub's answer as the page's view. A row without a workspace or a
 * YYYY-MM month is dropped: it could not be marked paid.
 * @param {unknown} body
 */
export function overdueInvoicesOf(body) {
  const b = body && typeof body === 'object' ? /** @type {Record<string, any>} */ (body) : {}
  const list = Array.isArray(b.invoices) ? b.invoices : []
  const invoices = []
  for (const x of list) {
    if (!x || typeof x !== 'object') continue
    const workspace = str(x.workspace)
    const month = str(x.month)
    if (!workspace || !MONTH_RE.test(month)) continue
    invoices.push({
      workspace,
      workspaceName: str(x.workspace_name),
      month,
      currency: CUR_RE.test(str(x.currency)) ? x.currency : '',
      humans: int(x.humans),
      totalMicros: str(x.total_micros),
      issuedOn: DATE_RE.test(str(x.issued_on)) ? x.issued_on : '',
      dueOn: DATE_RE.test(str(x.due_on)) ? x.due_on : '',
      daysOverdue: int(x.days_overdue),
      remindedAt: str(x.reminded_at),
    })
  }
  return { asOf: str(b.as_of), invoices }
}

/**
 * An amount in micros of currency (the hub's numeric text, e.g.
 * "24650000.000000") as money in locale, two decimals; '' when it is no number.
 * @param {string} micros
 * @param {string} currency
 * @param {string} locale
 */
export function invoiceMoney(micros, currency, locale) {
  const n = Number(micros)
  if (micros === '' || !Number.isFinite(n)) return ''
  const v = n / 1e6
  try {
    if (currency) return new Intl.NumberFormat(locale || 'en', { style: 'currency', currency, minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(v)
  } catch { /* an unknown locale or currency: the plain figure below */ }
  return v.toFixed(2) + (currency ? ' ' + currency : '')
}

function mockForbidden(path) {
  const e = /** @type {Error & { status?: number, token?: string, permission?: string }} */ (new Error('only an admin of the operator workspace manages workspaces'))
  e.status = 403
  e.token = 'forbidden'
  e.permission = 'operator.workspaces'
  return mockRefused(path, e)
}

function mockStore() {
  try { return typeof localStorage === 'undefined' ? null : localStorage } catch { return null }
}

function mockPaid(store) {
  try {
    const v = JSON.parse((store && store.getItem(INVOICES_MOCK_PAID_KEY)) || '[]')
    return Array.isArray(v) ? v.filter((x) => typeof x === 'string') : []
  } catch { return [] }
}

/**
 * The mock's invoices: two private workspaces' October invoices, issued
 * 2026-11-03 and due 2026-11-17; the first is paid, so one is overdue.
 */
function mockInvoices(store) {
  const paid = new Set(['ws-acme/2026-10', ...mockPaid(store)])
  const rows = [
    { workspace: 'ws-acme', workspace_name: 'Acme', month: '2026-10', currency: 'EUR', humans: 3, seat_cents: 2700,
      vm_cost_micros: 12000000, vm_price_micros: '15960000.000000', total_micros: '42960000.000000',
      issued_on: '2026-11-03', due_on: '2026-11-17', reminded_at: null },
    { workspace: 'ws-north', workspace_name: 'North', month: '2026-10', currency: 'EUR', humans: 2, seat_cents: 1800,
      vm_cost_micros: 5000000, vm_price_micros: '6650000.000000', total_micros: '24650000.000000',
      issued_on: '2026-11-03', due_on: '2026-11-17', reminded_at: '2026-11-18T09:00:00Z' },
  ]
  return rows.filter((r) => !paid.has(r.workspace + '/' + r.month))
}

/** The mock's GET: 403 unless the e2e opted into the operator admin. */
export function mockOverdueInvoices(store = mockStore(), now = new Date()) {
  const get = (k) => { try { return store ? store.getItem(k) : null } catch { return null } }
  if (get(TOKENS_MOCK_OPERATOR_KEY) !== '1') throw mockForbidden('/v1/operator/invoices/overdue')
  const day = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())
  const invoices = mockInvoices(store).map((r) => ({ ...r, days_overdue: Math.max(0, Math.round((day - Date.parse(r.due_on + 'T00:00:00Z')) / 86400000)) }))
  return { as_of: isoSeconds(now), invoices }
}

/** The mock's mark paid: 403 as the GET, 404 for an invoice it does not hold, 409 when already paid. */
export function mockMarkInvoicePaid(workspace, month, store = mockStore(), now = new Date()) {
  const get = (k) => { try { return store ? store.getItem(k) : null } catch { return null } }
  if (get(TOKENS_MOCK_OPERATOR_KEY) !== '1') throw mockForbidden(invoicePaidPath(workspace, month))
  const key = workspace + '/' + month
  if (!mockInvoices(store).some((r) => r.workspace + '/' + r.month === key)) {
    const known = ['ws-acme/2026-10', 'ws-north/2026-10'].includes(key)
    const e = /** @type {Error & { status?: number, token?: string }} */ (new Error(known ? 'this invoice is already marked paid' : 'no invoice of this workspace for this month'))
    e.status = known ? 409 : 404
    e.token = known ? 'already_paid' : 'not_found'
    throw e
  }
  try { store && store.setItem(INVOICES_MOCK_PAID_KEY, JSON.stringify([...mockPaid(store), key])) } catch { /* none */ }
  return { workspace, month, paid_at: isoSeconds(now) }
}
