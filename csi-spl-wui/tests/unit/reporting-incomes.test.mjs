// SPL-4697 (spec 143 incomes.md): the Reporting Incomes tab's month rows,
// year totals, owner gate and mock read. Synthetic rows only (csi-spl is
// public). RED CONTROL (base): utils/reporting-incomes.mjs did not exist.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { formatIncomeAmount, incomeMonthRows, incomeYearTotals, mockIncomesReport } from '../../src/utils/reporting-incomes.mjs'
import { ownerReadable, reportingOwner } from '../../src/utils/read-gates.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const inv = (no, period, net, vat, currency = 'EUR', hours = 1) =>
  ({ invoice_no: no, payer: 'ACME', period, issue_date: period + '-28', due_date: period + '-28', hours, unit_price: 1, net, vat_pct: 25, vat, total: Math.round((net + vat) * 100) / 100, currency })
/** a fake localStorage holding spool.mock.me */
const asRole = (role) => ({ getItem: (k) => (k === 'spool.mock.me' ? JSON.stringify({ role, permissions: [] }) : null) })

describe('incomeMonthRows', () => {
  it('twelve months, January first; a month with no invoice is empty (the page draws a dash), one with two holds both', () => {
    const rows = incomeMonthRows({ year: 2025, invoices: [inv('A', '2025-02', 1, 0.25), inv('B', '2025-02', 2, 0.5), inv('C', '2025-12', 3, 0.75), inv('X', '2024-02', 9, 0)] })
    assert.deepEqual(rows.map((r) => r.month), Array.from({ length: 12 }, (_, i) => `2025-${String(i + 1).padStart(2, '0')}`))
    assert.deepEqual(rows.map((r) => r.invoices.map((i) => i.invoice_no).join(',')), ['', 'A,B', '', '', '', '', '', '', '', '', '', 'C'])
  })
  it('no report: twelve empty months, never a throw', () => {
    assert.equal(incomeMonthRows({ year: 2025 }).every((r) => r.invoices.length === 0), true)
  })
})

describe('incomeYearTotals', () => {
  it('sums in cents per currency, in first-seen order; no FX', () => {
    const t = incomeYearTotals({ year: 2025, invoices: [inv('A', '2025-01', 0.1, 0.2), inv('B', '2025-02', 0.2, 0.1, 'USD', 2.5), inv('C', '2025-03', 0.2, 0.1)] })
    assert.deepEqual(t, [
      { currency: 'EUR', count: 2, hours: 2, net: 0.3, vat: 0.3, total: 0.6 },
      { currency: 'USD', count: 1, hours: 2.5, net: 0.2, vat: 0.1, total: 0.3 },
    ])
    /* RED control: a float sum drifts (0.1 + 0.2 !== 0.3), the cents sum does not */
    assert.notEqual(0.1 + 0.2, 0.3)
  })
  it('an empty year has no total row', () => {
    assert.deepEqual(incomeYearTotals({ year: 2025, invoices: [] }), [])
  })
})

describe('the owner gate (hub TenantOwner)', () => {
  it('the owner reads; an admin, a member and an operator admin do not', () => {
    for (const me of [{ tenantOwner: true, role: 'admin', permissions: [] }, { role: 'biz_owner', permissions: [] }, { role: 'member', roles: ['biz_owner'], permissions: [] }]) {
      assert.equal(reportingOwner(me), true, JSON.stringify(me))
      assert.equal(ownerReadable(me), true, JSON.stringify(me))
    }
    for (const me of [{ role: 'admin', permissions: [] }, { role: 'member', permissions: [] }, { role: 'admin', operatorAdmin: true, permissions: [] }]) {
      assert.equal(reportingOwner(me), false, JSON.stringify(me))
      assert.equal(ownerReadable(me), false, JSON.stringify(me))
    }
    assert.equal(reportingOwner(null), false)
  })
})

describe('mockIncomesReport', () => {
  it('the owner (or no mock role) gets two invoices and a gap in March; another role the 403', () => {
    for (const store of [asRole('biz_owner'), { getItem: () => null }]) {
      const r = mockIncomesReport(2025, store)
      assert.equal(r.year, 2025)
      assert.deepEqual(r.invoices.map((i) => i.period), ['2025-01', '2025-02'])
      assert.equal(r.invoices.every((i) => Math.round((i.net + i.vat) * 100) === Math.round(i.total * 100)), true)
    }
    for (const role of ['admin', 'member']) {
      assert.throws(() => mockIncomesReport(2025, asRole(role)), (e) => e.status === 403, role)
    }
    assert.deepEqual(mockIncomesReport(2024, { getItem: () => null }).invoices, [])
  })
})

describe('formatIncomeAmount', () => {
  it('two decimals and the currency; a bad currency still prints the number', () => {
    assert.match(formatIncomeAmount(1234.5, 'EUR', 'en'), /1,234\.50/)
    assert.match(formatIncomeAmount(1234.5, 'EUR', 'en'), /€/)
    assert.equal(formatIncomeAmount(1, 'x', 'en'), '1.00 x')
  })
})

describe('the page', () => {
  it('reads the owner gate first, draws a dash for a missing month, never writes', () => {
    const page = readFileSync(join(WUI, 'src/pages/reporting/incomes.vue'), 'utf8')
    assert.match(page, /ownerReadable\(await gateMe\(access\)\)/)
    assert.match(page, /v-if="!row\.invoices\.length"[^>]*>\s*<th[^>]*>[^<]*<\/th>\s*<td colspan="7"[^>]*>–<\/td>/)
    assert.doesNotMatch(page, /method:\s*'(POST|PUT|PATCH|DELETE)'/)
  })
})
