// SPL-5433 step d (spec 123 16.5; owner HUM-10, t1 2d974709, poll 2ff12c21
// answer 4 B): the worker side on the HR tab (utils/hr-costs.mjs): the band,
// tax card and payslip forms and their checks, the hub's worker side as read,
// and the mock's calculation, which follows the hub's (store.ComputeHRWorker:
// the same made-up figures as hub/hr_worker_test.go). Made-up people, lines,
// bands, cards and payslips only.
//
// Run: node --test tests/unit/hr-worker.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  checkHrPayslipForm, checkHrTaxCardForm, emptyHrBandForm, emptyHrPayslipForm, emptyHrTaxCardForm, hrBandsWith, hrPayslipBody,
  hrTaxCardBody, hrTaxCardsOf, hrWorkerLineNote, hrWorkerOf, hrWorkerRatesOf,
  mockHrPayroll, mockHrPayslipDelete, mockHrPayslipSet, mockHrPeriodSet, mockHrPersonCreate, mockHrTaxCardDelete, mockHrTaxCards,
  mockHrTaxCardSet, mockHrWorkerRates, mockHrWorkerRatesSet,
} from '../../src/utils/hr-costs.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'

const memStore = (init = {}) => {
  const m = new Map(Object.entries(init))
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }
}
const opStore = () => memStore({ [TOKENS_MOCK_OPERATOR_KEY]: '1' })
const NOV3 = new Date('2026-11-03T10:00:00Z')
const line = (pid, period, amount) => ({ id: 'l-' + period + '-' + amount, type: 'hr', label: 'test line', amount, currency: 'EUR', period,
  person_id: pid, component: 'monthly_salary', source: 'payslip', period_kind: 'month' })

describe('forms', () => {
  it('adds a band to the current ones, refusing an overlap', () => {
    const cur = [{ kind: 'tyel_employee', ageFrom: 17, ageTo: 52, ratePct: 7, source: '' }, { kind: 'unemployment_employee', ageFrom: 17, ageTo: 64, ratePct: 1, source: '' }]
    const ok = { ...emptyHrBandForm(), ageFrom: '53', ageTo: '62', ratePct: '8,5' }
    assert.deepEqual(hrBandsWith(ok, cur), { problem: '', bands: [{ age_from: 17, age_to: 52, rate_pct: 7 }, { age_from: 53, age_to: 62, rate_pct: 8.5 }] })
    for (const [why, f] of [
      ['err_band_kind', { ...ok, kind: 'tax' }], ['err_band_ages', { ...ok, ageFrom: '63', ageTo: '62' }], ['err_band_ages', { ...ok, ageTo: '121' }],
      ['err_band_ages', { ...ok, ageFrom: '1.5' }], ['err_band_pct', { ...ok, ratePct: '100' }], ['err_band_pct', { ...ok, ratePct: '1.23456' }],
      ['err_band_overlap', { ...ok, ageFrom: '52' }], ['err_band_source', { ...ok, source: 'x'.repeat(201) }],
    ]) assert.equal(hrBandsWith(f, cur).problem, why, JSON.stringify(f))
  })
  it('checks a tax card as the hub does', () => {
    const ok = { ...emptyHrTaxCardForm(), personId: 'p1', basePct: '20,5', extraPct: '40', incomeLimit: '30000.50', source: 'made-up' }
    assert.equal(checkHrTaxCardForm(ok), '')
    assert.deepEqual(hrTaxCardBody(ok), { base_pct: 20.5, extra_pct: 40, income_limit: 30000.5, source: 'made-up' })
    for (const [why, f] of [
      ['err_card_person', { ...ok, personId: '' }], ['err_card_base', { ...ok, basePct: '' }], ['err_card_base', { ...ok, basePct: '20.555' }],
      ['err_card_extra', { ...ok, extraPct: '100' }], ['err_card_limit', { ...ok, incomeLimit: '-1' }], ['err_card_limit', { ...ok, incomeLimit: 'x' }],
    ]) assert.equal(checkHrTaxCardForm(f), why, JSON.stringify(f))
  })
  it('checks a payslip: at least one value, only net below 0, and sends only what was typed', () => {
    const ok = { ...emptyHrPayslipForm(), personId: 'p1', tax_withheld: '812,50', net_pay: '-5' }
    assert.equal(checkHrPayslipForm(ok), '')
    assert.deepEqual(hrPayslipBody(ok), { currency: 'EUR', tax_withheld: 812.5, net_pay: -5 })
    for (const [why, f] of [
      ['err_slip_person', { ...ok, personId: '' }], ['err_slip_currency', { ...ok, currency: 'eur' }],
      ['err_slip_amount', { ...ok, tax_withheld: '-1' }], ['err_slip_amount', { ...ok, net_pay: '1.234' }],
      ['err_slip_empty', { ...emptyHrPayslipForm(), personId: 'p1' }],
    ]) assert.equal(checkHrPayslipForm(f), why, JSON.stringify(f))
  })
})

describe('the hub answer', () => {
  it('reads the worker side, bands and cards; nothing when the hub sent none', () => {
    const w = hrWorkerOf({ worker: [{ person_id: 'p1', code: 'E-01', currency: 'EUR', age: 35, gross: 3000, ytd_before: 3000, ytd: 6000,
      tax_card: { base_pct: 20, extra_pct: 40, income_limit: 5000 }, missing: ['tax_card', 'other'],
      shares: [{ kind: 'tyel_employee', rate_pct: 7, computed: 210, amount: 210 }],
      tax: { kind: 'tax_withheld', computed: 800, typed: 999, amount: 999, diff: 199, flag: 'diff' }, net: { kind: 'net_pay', computed: 1761, amount: 1761 }, flags: 1 }, {}] })
    assert.equal(w.length, 1)
    assert.deepEqual(w[0].missing, ['tax_card'])
    assert.deepEqual(hrWorkerLineNote(w[0].tax), { key: 'diff', amount: 199 })
    assert.deepEqual(hrWorkerLineNote(w[0].net), { key: 'computed', amount: 1761 })
    assert.deepEqual(hrWorkerOf({ people: [] }), [])
    assert.deepEqual(hrWorkerRatesOf({ rates: [{ kind: 'unemployment_employee', age_from: 17, age_to: 64, rate_pct: 1 }, { kind: 'tyel_employee', age_from: 53, age_to: 62, rate_pct: 8.5 }, { kind: 'tax' }] }).map((r) => r.kind + r.ageFrom),
      ['tyel_employee53', 'unemployment_employee17'])
    assert.deepEqual(hrTaxCardsOf({ tax_cards: [{ person_id: 'p1', base_pct: 20, extra_pct: 40, income_limit: 5000 }, {}] }).length, 1)
  })
})

describe('the mock', () => {
  it('computes the hub test\'s figures: shares by age band, tax across the limit, the payslip winning and flagged', () => {
    const st = opStore()
    const p = mockHrPersonCreate({ code: 'W-01', name: 'FirstName LastName', employment_type: 'employee', birth_year: 1970 }, st, NOV3)
    st.setItem('spool.mock.cost_entries', JSON.stringify([line(p.id, '2005-01', 3000), line(p.id, '2005-03', 3000)]))
    mockHrPeriodSet('2005-03', 'reopen', 'test fixture month', st, NOV3)
    mockHrWorkerRatesSet('2005', { kind: 'tyel_employee', bands: [{ age_from: 17, age_to: 64, rate_pct: 7 }], source: 'made-up' }, st, NOV3)
    mockHrWorkerRatesSet('2005', { kind: 'unemployment_employee', bands: [{ age_from: 17, age_to: 64, rate_pct: 1 }] }, st, NOV3)
    assert.equal(mockHrWorkerRates('2005', st).rates.length, 2)
    mockHrTaxCardSet('2005', { person_id: p.id, base_pct: 20, extra_pct: 40, income_limit: 5000, source: 'made-up' }, st, NOV3)
    mockHrPayslipSet('2005-03', { person_id: p.id, currency: 'EUR', tax_withheld: 999 }, st, NOV3)
    const [w] = hrWorkerOf(mockHrPayroll('2005-03', st, NOV3))
    assert.equal(w.age, 35)
    assert.equal(w.ytdBefore, 3000)
    assert.deepEqual(w.shares.map((l) => l.computed), [210, 30])
    assert.equal(w.tax.computed, 800)
    assert.equal(w.tax.flag, 'diff')
    assert.equal(w.net.computed, 1761)
    assert.equal(w.flags, 1)
    assert.equal(mockHrPayroll('2005-03', st, NOV3).people[0].cost, 3000)
  })
  it('says what is missing, refuses a payslip in a closed month, deletes', () => {
    const st = opStore()
    const p = mockHrPersonCreate({ code: 'W-02', name: 'FirstName LastName', employment_type: 'hourly' }, st, NOV3)
    st.setItem('spool.mock.cost_entries', JSON.stringify([line(p.id, '2026-10', 1000)]))
    mockHrWorkerRatesSet('2026', { kind: 'tyel_employee', bands: [{ age_from: 17, age_to: 64, rate_pct: 7 }] }, st, NOV3)
    const [w] = hrWorkerOf(mockHrPayroll('2026-10', st, NOV3))
    assert.deepEqual(w.missing, ['birth_year', 'tax_card'])
    assert.equal(w.net.computed, 1000)
    mockHrPeriodSet('2026-10', 'close', '', st, NOV3)
    assert.throws(() => mockHrPayslipSet('2026-10', { person_id: p.id, currency: 'EUR', net_pay: 1 }, st, NOV3), (e) => e.status === 409)
    assert.throws(() => mockHrPayslipDelete('2026-10', { person_id: p.id }, st, NOV3), (e) => e.status === 409)
    assert.throws(() => mockHrTaxCardSet('2026', { person_id: 'nobody', base_pct: 1, extra_pct: 2, income_limit: 3 }, st, NOV3), (e) => e.status === 404)
    mockHrTaxCardSet('2026', { person_id: p.id, base_pct: 1, extra_pct: 2, income_limit: 3 }, st, NOV3)
    assert.equal(mockHrTaxCards('2026', st).tax_cards.length, 1)
    mockHrTaxCardDelete('2026', p.id, st)
    assert.throws(() => mockHrTaxCardDelete('2026', p.id, st), (e) => e.status === 404)
  })
})
