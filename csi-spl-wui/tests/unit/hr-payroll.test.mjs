// SPL-5433 step c (spec 123 16.4; owner HUM-10, t1 2d974709, poll 2ff12c21
// answer 4 B): the employer side on the HR tab (utils/hr-costs.mjs): the
// rate form and its checks, the hub's payroll answer as read, and the mock's
// calculation and book, which follow the hub's (store.ComputeHRPayroll).
// Made-up people, lines and rates only.
//
// Run: node --test tests/unit/hr-payroll.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  checkHrRateForm, emptyHrRateForm, hrPayrollLineNote, hrPayrollOf, hrRateBody, hrRateComponents, hrRatesOf,
  mockHrComponents, mockHrPayroll, mockHrPayrollBook, mockHrPersonCreate, mockHrRateDelete, mockHrRates, mockHrRateSet,
} from '../../src/utils/hr-costs.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'

const memStore = (init = {}) => {
  const m = new Map(Object.entries(init))
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }
}
const opStore = () => memStore({ [TOKENS_MOCK_OPERATOR_KEY]: '1' })
const NOV3 = new Date('2026-11-03T10:00:00Z')

describe('rates', () => {
  const comps = mockHrComponents(opStore()).components
  it('offers the employer contributions, never yel or a pay component', () => {
    const ids = hrRateComponents(comps).map((c) => c.component)
    assert.ok(ids.includes('tyel_employer') && ids.includes('unemployment_employer'))
    assert.ok(!ids.includes('yel') && !ids.includes('monthly_salary'))
  })
  it('checks the form as the hub does', () => {
    const ok = { ...emptyHrRateForm(), component: 'tyel_employer', ratePct: '17,3456', source: 'made-up' }
    assert.equal(checkHrRateForm(ok, comps), '')
    assert.deepEqual(hrRateBody(ok), { rate_pct: 17.3456, applies_to: ['employee', 'hourly'], source: 'made-up' })
    for (const [why, f] of [
      ['err_rate_component', { ...ok, component: 'yel' }], ['err_rate_component', { ...ok, component: 'monthly_salary' }],
      ['err_rate_pct', { ...ok, ratePct: '' }], ['err_rate_pct', { ...ok, ratePct: '100' }], ['err_rate_pct', { ...ok, ratePct: '-1' }],
      ['err_rate_pct', { ...ok, ratePct: '1.23456' }], ['err_rate_pct', { ...ok, ratePct: 'x' }],
      ['err_rate_types', { ...ok, appliesTo: [] }], ['err_rate_types', { ...ok, appliesTo: ['intern'] }],
      ['err_rate_source', { ...ok, source: 'x'.repeat(201) }],
    ]) assert.equal(checkHrRateForm(f, comps), why, JSON.stringify(f))
  })
  it('reads the hub answer and keeps only known employment types', () => {
    const got = hrRatesOf({ year: 2026, rates: [{ component: 'tyel_employer', rate_pct: 17.5, applies_to: ['employee', 'intern'], source: 's', set_by: 'HUM-1' }, { component: 'accident_insurance', rate_pct: 1, applies_to: ['hourly'] }, {}] })
    assert.equal(got.year, 2026)
    assert.deepEqual(got.rates.map((r) => r.component), ['accident_insurance', 'tyel_employer'])
    assert.deepEqual(got.rates[1].appliesTo, ['employee'])
    assert.deepEqual(hrRatesOf(null), { year: null, rates: [] })
  })
  it('the mock sets, lists per year, refuses yel and deletes', () => {
    const st = opStore()
    mockHrRateSet('2026', 'tyel_employer', { rate_pct: 17.5, applies_to: ['employee'], source: 'made-up' }, st)
    mockHrRateSet('2025', 'tyel_employer', { rate_pct: 16, applies_to: ['employee'] }, st)
    assert.deepEqual(mockHrRates('2026', st).rates.map((r) => r.rate_pct), [17.5])
    assert.throws(() => mockHrRateSet('2026', 'yel', { rate_pct: 1, applies_to: ['employee'] }, st), (e) => e.status === 400)
    mockHrRateDelete('2026', 'tyel_employer', st)
    assert.equal(mockHrRates('2026', st).rates.length, 0)
    assert.throws(() => mockHrRateDelete('2026', 'tyel_employer', st), (e) => e.status === 404)
  })
})

describe('payroll', () => {
  it('reads the hub answer: codes, lines, totals, what Book would write, the month lock', () => {
    const p = hrPayrollOf({
      month: '2026-10', flags: 2, period: { closed: false },
      people: [{ person_id: 'p1', code: 'E-01', employment_type: 'employee', currency: 'EUR', gross: 4000, employer_total: 700.5, other: 10, cost: 4710.5, flags: 2,
        employer: [{ component: 'tyel_employer', rate_pct: 17.5, computed: 700, typed: 700.5, amount: 700.5, diff: 0.5, flag: 'diff' },
          { component: 'accident_insurance', rate_pct: 1, computed: 40, booked: 30, amount: 30, diff: -10, flag: 'stale' }, { component: 'x', flag: 'weird' }] }],
      totals: [{ currency: 'EUR', gross: 4000, employer_total: 700.5, other: 10, cost: 4710.5, to_book: 1 }],
    })
    assert.equal(p.month, '2026-10')
    assert.equal(p.people[0].employer[0].typed, 700.5)
    assert.equal(p.people[0].employer[2].flag, '')
    assert.equal(p.toBook, 2, 'one to book + one stale')
    assert.equal(p.closed, false)
    assert.deepEqual(hrPayrollLineNote(p.people[0].employer[0]), { key: 'diff', amount: 0.5 })
    assert.deepEqual(hrPayrollLineNote(p.people[0].employer[1]), { key: 'stale', amount: 40 })
    assert.deepEqual(hrPayrollOf(undefined), { month: '', people: [], totals: [], flags: 0, toBook: 0, closed: false })
  })

  it('the mock computes, a typed line wins and is flagged, Book writes once, a rate change is stale and rebooked', () => {
    const st = opStore()
    const p1 = mockHrPersonCreate({ code: 'E-01', name: 'FirstName LastName', employment_type: 'employee' }, st, NOV3)
    const line = (component, amount, source = 'payslip') => ({ type: 'hr', label: component, amount, currency: 'EUR', period: '2026-10', person_id: p1.id, component, source, period_kind: 'month' })
    st.setItem('spool.mock.cost_entries', JSON.stringify([line('monthly_salary', 4000), line('overtime', 200), line('mileage', 50, ''), line('unemployment_employer', 9)]))
    mockHrRateSet('2026', 'tyel_employer', { rate_pct: 10, applies_to: ['employee'] }, st)
    mockHrRateSet('2026', 'unemployment_employer', { rate_pct: 0.2, applies_to: ['employee'] }, st)
    let p = hrPayrollOf(mockHrPayroll('2026-10', st, NOV3))
    const by = (q) => Object.fromEntries(q.people[0].employer.map((l) => [l.component, l]))
    assert.equal(p.people[0].gross, 4200)
    assert.equal(p.people[0].other, 50)
    assert.equal(by(p).tyel_employer.computed, 420)
    assert.equal(by(p).unemployment_employer.flag, 'diff')
    assert.equal(p.people[0].cost, 4200 + 420 + 9 + 50)
    assert.equal(p.toBook, 1)
    const b = mockHrPayrollBook('2026-10', st, NOV3)
    assert.equal(b.booked, 1)
    assert.equal(mockHrPayrollBook('2026-10', st, NOV3).booked, 0, 'a second book writes nothing')
    mockHrRateSet('2026', 'tyel_employer', { rate_pct: 12, applies_to: ['employee'] }, st)
    p = hrPayrollOf(mockHrPayroll('2026-10', st, NOV3))
    assert.equal(by(p).tyel_employer.flag, 'stale')
    const again = mockHrPayrollBook('2026-10', st, NOV3)
    assert.deepEqual([again.booked, again.removed], [1, 1])
    const tyel = JSON.parse(st.getItem('spool.mock.cost_entries')).filter((e) => e.component === 'tyel_employer')
    assert.deepEqual(tyel.map((e) => e.amount), [504])
  })

  it('the mock refuses to book a closed month', () => {
    const st = opStore()
    assert.throws(() => mockHrPayrollBook('2026-09', st, NOV3), (e) => e.status === 409)
  })
})
