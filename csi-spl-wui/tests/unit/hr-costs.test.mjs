// SPL-5433 (spec 123 16.2; owner HUM-10, t1 2d974709, polls a82c0089,
// 2ff12c21, 12c458ad): the HR tab's people, components and month lock
// (utils/hr-costs.mjs), the hr line's fields in the add form
// (utils/cost-entries.mjs), who sees Expenses (utils/access.mjs,
// utils/expenses-tabs.mjs) and the strings in every locale.
//
// Run: node --test tests/unit/hr-costs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  checkHrPersonForm, emptyHrPersonForm, hrCloseDay, hrClosedByRule, hrComponentGroups, hrComponentsOf, hrLineLabel, hrPeopleOf, hrPeriodOf, hrPersonBody,
  mockHrPeriod, mockHrPeriodSet, mockHrPersonCreate, mockHrPeople,
} from '../../src/utils/hr-costs.mjs'
import { checkCostEntryForm, costEntriesOf, costEntryBody, emptyCostEntryForm } from '../../src/utils/cost-entries.mjs'
import { expensesReads, normalizeMe } from '../../src/utils/access.mjs'
import { visibleExpensesTabs } from '../../src/utils/expenses-tabs.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const memStore = (init = {}) => {
  const m = new Map(Object.entries(init))
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }
}

describe('people', () => {
  it('reads the hub answer, names only when sent', () => {
    const got = hrPeopleOf({ names: false, people: [{ id: 'b', code: 'E-02', department: 'Dev', employment_type: 'hourly' }, { id: 'a', code: 'E-01', name: 'FirstName LastName', employment_type: 'employee', birth_year: 1990 }, { code: 'X-01' }] })
    assert.equal(got.names, false)
    assert.deepEqual(got.people.map((p) => p.code), ['E-01', 'E-02'])
    assert.equal(got.people[0].birthYear, 1990)
    assert.equal(hrPeopleOf(null).people.length, 0)
  })
  it('checks a person form as rdb 0279 does', () => {
    const ok = { ...emptyHrPersonForm(), code: 'E-01', name: 'FirstName LastName' }
    assert.equal(checkHrPersonForm(ok), '')
    assert.equal(checkHrPersonForm({ ...ok, code: 'e-01' }), 'err_code')
    assert.equal(checkHrPersonForm(ok, [{ code: 'E-01' }]), 'err_code_taken')
    assert.equal(checkHrPersonForm({ ...ok, name: ' ' }), 'err_name')
    assert.equal(checkHrPersonForm({ ...ok, employmentType: 'intern' }), 'err_type')
    assert.equal(checkHrPersonForm({ ...ok, birthYear: '1800' }), 'err_birth_year')
    assert.deepEqual(hrPersonBody({ ...ok, birthYear: '1990' }), { code: 'E-01', name: 'FirstName LastName', department: '', employment_type: 'employee', birth_year: 1990 })
    assert.equal('birth_year' in hrPersonBody(ok), false)
  })
  it('the mock refuses a taken code and needs the operator opt-in', () => {
    const st = memStore({ [TOKENS_MOCK_OPERATOR_KEY]: '1' })
    mockHrPersonCreate({ code: 'E-01', name: 'FirstName LastName', employment_type: 'employee' }, st)
    assert.throws(() => mockHrPersonCreate({ code: 'E-01', name: 'x', employment_type: 'employee' }, st), (e) => e.status === 409)
    assert.equal(mockHrPeople(st).people.length, 1)
    assert.throws(() => mockHrPeople(memStore()), (e) => e.status === 403)
  })
})

describe('components and lines', () => {
  it('groups the components in the 8 groups order', () => {
    const cs = hrComponentsOf({ components: [{ component: 'bonus', group: 'bonuses_incentives', label: 'Bonus' }, { component: 'monthly_salary', group: 'salaries_wages', label: 'Monthly salary' }] })
    assert.deepEqual(hrComponentGroups(cs).map((g) => g.group), ['salaries_wages', 'bonuses_incentives'])
    assert.equal(hrLineLabel({ code: 'E-01' }, { label: 'Monthly salary' }), 'E-01 · Monthly salary')
  })
  it('an hr line carries its fields; a cloud line none', () => {
    const f = { ...emptyCostEntryForm(new Date('2026-10-15T00:00:00Z')), label: 'E-01 · Monthly salary', amount: '4000', currency: 'EUR', personId: 'p1', component: 'monthly_salary', source: 'payslip 2026-10', correctsPeriod: '2026-08' }
    assert.equal(checkCostEntryForm(f, ['EUR']), '')
    assert.deepEqual(costEntryBody('hr', f), { type: 'hr', label: 'E-01 · Monthly salary', amount: 4000, currency: 'EUR', period: '2026-10', note: '', person_id: 'p1', component: 'monthly_salary', source: 'payslip 2026-10', corrects_period: '2026-08' })
    assert.equal('person_id' in costEntryBody('cloud', f), false)
    assert.equal(checkCostEntryForm({ ...f, component: '' }, ['EUR']), 'err_component')
    assert.equal(checkCostEntryForm({ ...f, periodKind: 'year' }, ['EUR']), 'err_year')
    assert.equal(costEntryBody('hr', { ...f, period: '2026-01', periodKind: 'year', correctsPeriod: '' }).period_kind, 'year')
    assert.equal(checkCostEntryForm({ ...f, correctsPeriod: '2026-10' }, ['EUR']), 'err_corrects')
    const [row] = costEntriesOf({ entries: [{ id: 'x', type: 'hr', person_id: 'p1', component: 'bonus', period_kind: 'month', corrects_period: '2026-08' }] })
    assert.deepEqual([row.personId, row.component, row.periodKind, row.correctsPeriod], ['p1', 'bonus', 'month', '2026-08'])
  })
})

describe('the month lock', () => {
  it('a month closes on the 6th of the next month', () => {
    assert.equal(hrCloseDay('2026-10'), '2026-11-06')
    assert.equal(hrCloseDay('2026-12'), '2027-01-06')
    assert.equal(hrClosedByRule('2026-10', new Date('2026-11-05T12:00:00Z')), false)
    assert.equal(hrClosedByRule('2026-10', new Date('2026-11-06T12:00:00Z')), true)
    assert.equal(hrPeriodOf({ period: '2026-10', closed: true }).closed, true)
    assert.equal(hrPeriodOf({ period: 'x' }), null)
  })
  it('the mock reopens with a reason only, and closes again', () => {
    const st = memStore({ [TOKENS_MOCK_OPERATOR_KEY]: '1' })
    const now = new Date('2026-11-13T00:00:00Z')
    assert.equal(mockHrPeriod('2026-09', st, now).closed, true)
    assert.throws(() => mockHrPeriodSet('2026-09', 'reopen', ' ', st, now), (e) => e.status === 400)
    assert.equal(mockHrPeriodSet('2026-09', 'reopen', 'late payslip', st, now).closed, false)
    assert.equal(mockHrPeriodSet('2026-09', 'close', '', st, now).closed, true)
  })
})

describe('who sees Expenses', () => {
  it('a costs.write member of the operator workspace sees Cloud and HR, not AI', () => {
    const me = normalizeMe({ human_id: 'HUM-1', operator_reader: false, cost_writer: true })
    assert.equal(me.costWriter, true)
    /* the rail opens on expensesReads || costWriter (useRailOrder); expensesReads alone stays the hub's expenses_reader */
    assert.equal(expensesReads(me, false) || me.costWriter, true)
    assert.deepEqual(visibleExpensesTabs({ operator: false, costs: true }).map((x) => x.id), ['cloud', 'hr'])
    const other = normalizeMe({ human_id: 'HUM-2', operator_reader: false })
    assert.equal(expensesReads(other, false) || other.costWriter, false)
    assert.deepEqual(visibleExpensesTabs({ operator: false }).map((x) => x.id), [])
  })
})

describe('strings', () => {
  it('every locale holds every hr key, with the same placeholders as en', () => {
    const dir = join(WUI, 'i18n/locales')
    const en = JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8')).expenses
    const flat = (o, pre = '') => Object.entries(o).flatMap(([k, v]) => (typeof v === 'object' ? flat(v, pre + k + '.') : [[pre + k, v]]))
    const want = flat(en.hr)
    for (const f of readdirSync(dir)) {
      const ex = JSON.parse(readFileSync(join(dir, f), 'utf8')).expenses
      const got = Object.fromEntries(flat(ex.hr || {}))
      for (const [k, v] of want) {
        assert.ok(got[k], `${f}: expenses.hr.${k}`)
        assert.deepEqual((got[k].match(/\{\w+\}/g) || []).sort(), (v.match(/\{\w+\}/g) || []).sort(), `${f}: expenses.hr.${k} placeholders`)
      }
      for (const k of ['err_component', 'err_source', 'err_year', 'err_corrects']) assert.ok(ex.entries[k], `${f}: expenses.entries.${k}`)
    }
  })
})
