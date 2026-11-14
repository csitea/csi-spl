// csi-spl-wui/src/utils/hr-costs.mjs
//
// SPL-5433 (spec 123 section 16.2; owner HUM-10, t1 2d974709, polls a82c0089,
// 2ff12c21, 12c458ad): the HR tab's people, components and month lock, over
// the hub's /v1/operator/hr-people, /hr-components and /cost-periods/{month}
// (spool-client-lazy.mjs fleetPaid 'hr_*'). A person is a code (E-01); the
// real name comes back only to a costs.write member (the accountants, the
// admin). A month of hr lines closes by itself on the 6th of the next month,
// 00:00 Europe/Helsinki; the operator admin reopens it (with a reason) and
// closes it. Loaded with the HR tab only.

import { mockError, mockGate, mockStore } from './monitoring-paid.mjs'

const HR_PEOPLE_MOCK_KEY = 'spool.mock.hr_people'
const HR_PERIODS_MOCK_KEY = 'spool.mock.hr_periods'
export const HR_EMPLOYMENT_TYPES = Object.freeze(['employee', 'hourly', 'owner_management', 'contractor'])
const HR_GROUPS = Object.freeze(['salaries_wages', 'employer_contributions', 'working_time_allowances',
  'bonuses_incentives', 'leave_absence', 'benefits_insurance', 'training_recruitment', 'transport_meals'])

const CODE_RE = /^[A-Z]{1,3}-[0-9]{2,4}$/
const MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])$/
const str = (v) => (typeof v === 'string' ? v : '')
const bytes = (s) => new TextEncoder().encode(s).length

/** The hub's components ({components}), in its order. */
export function hrComponentsOf(body) {
  const list = body && typeof body === 'object' && Array.isArray(body.components) ? body.components : []
  return list.filter((c) => c && str(c.component)).map((c) => ({ component: str(c.component), group: str(c.group), label: str(c.label) || str(c.component) }))
}

/** The components as select groups: [{ group, items }] in HR_GROUPS order. */
export function hrComponentGroups(components) {
  return HR_GROUPS.map((group) => ({ group, items: components.filter((c) => c.group === group) })).filter((g) => g.items.length)
}

/** The hub's people ({people, names}): names false = codes only. */
export function hrPeopleOf(body) {
  const b = body && typeof body === 'object' ? body : {}
  const list = Array.isArray(b.people) ? b.people : []
  return {
    names: b.names === true,
    people: list.filter((p) => p && str(p.id) && str(p.code)).map((p) => ({
      id: str(p.id),
      code: str(p.code),
      name: str(p.name),
      department: str(p.department),
      employmentType: str(p.employment_type),
      birthYear: Number.isInteger(p.birth_year) ? p.birth_year : null,
    })).sort((a, b2) => a.code.localeCompare(b2.code)),
  }
}

/** A blank person form. */
export function emptyHrPersonForm() {
  return { code: '', name: '', department: '', employmentType: 'employee', birthYear: '' }
}

/** The first thing wrong with a person form, as an i18n key suffix ('' = fine); the hub's rdb 0279 CHECKs. */
export function checkHrPersonForm(f, people = []) {
  const code = str(f.code).trim()
  const name = str(f.name).trim()
  if (!CODE_RE.test(code)) return 'err_code'
  if (people.some((p) => p.code === code)) return 'err_code_taken'
  if (!name || bytes(name) > 200) return 'err_name'
  if (bytes(str(f.department)) > 100) return 'err_department'
  if (!HR_EMPLOYMENT_TYPES.includes(f.employmentType)) return 'err_type'
  if (f.birthYear !== '' && f.birthYear !== null && !(Number.isInteger(Number(f.birthYear)) && Number(f.birthYear) >= 1900 && Number(f.birthYear) <= 2100)) return 'err_birth_year'
  return ''
}

/** The POST body of a checked person form. */
export function hrPersonBody(f) {
  const body = { code: str(f.code).trim(), name: str(f.name).trim(), department: str(f.department).trim(), employment_type: f.employmentType }
  if (f.birthYear !== '' && f.birthYear !== null) body.birth_year = Number(f.birthYear)
  return body
}

/** An hr line's default label: the person's code and the component's label. */
export function hrLineLabel(person, component) {
  return [person && person.code, component && component.label].filter(Boolean).join(' · ').slice(0, 100)
}

/** The hub's month state; null on a body that is not one. */
export function hrPeriodOf(body) {
  if (!body || typeof body !== 'object' || !MONTH_RE.test(str(body.period))) return null
  return { period: body.period, closed: body.closed === true, closesAt: str(body.closes_at), reopenReason: str(body.reopen_reason) }
}

/** The day a month closes, as YYYY-MM-DD in Helsinki (the 6th of the next month). */
export function hrCloseDay(month) {
  if (!MONTH_RE.test(str(month))) return ''
  const [y, m] = month.split('-').map(Number)
  const ny = m === 12 ? y + 1 : y
  const nm = m === 12 ? 1 : m + 1
  return `${ny}-${String(nm).padStart(2, '0')}-06`
}

/** Whether month is closed at now by the rule alone (no reopen known): the mock's and a fallback's. */
export function hrClosedByRule(month, now = new Date()) {
  const day = hrCloseDay(month)
  if (!day) return false
  /* 00:00 Europe/Helsinki is 22:00 or 21:00 UTC the day before; the earlier one is the safe side for a hint */
  return now.getTime() >= Date.parse(day + 'T00:00:00+03:00')
}

function mockRead(store, key) {
  try {
    const v = JSON.parse((store && store.getItem(key)) || '[]')
    return Array.isArray(v) || (v && typeof v === 'object') ? v : []
  } catch {
    return []
  }
}

function mockWrite(store, key, v) {
  try { store.setItem(key, JSON.stringify(v)) } catch { /* the mock forgets */ }
}

/** The mock's components: a few of rdb 0279's seed, one per group. */
export function mockHrComponents(store = mockStore()) {
  mockGate(store)
  const c = (component, group, label) => ({ component, group, label })
  return { components: [
    c('monthly_salary', 'salaries_wages', 'Monthly salary'), c('hourly_pay', 'salaries_wages', 'Hourly pay (hours x rate)'),
    c('tyel_employer', 'employer_contributions', "TyEL, employer's share"), c('yel', 'employer_contributions', "YEL, entrepreneur's pension"),
    c('unemployment_employer', 'employer_contributions', "Unemployment insurance, employer's share"), c('overtime', 'working_time_allowances', 'Overtime'),
    c('bonus', 'bonuses_incentives', 'Bonus or incentive'), c('holiday_bonus', 'leave_absence', 'Holiday bonus (lomaraha)'),
    c('occupational_healthcare', 'benefits_insurance', 'Occupational healthcare'), c('training', 'training_recruitment', 'Training'),
    c('mileage', 'transport_meals', 'Mileage allowance'),
  ] }
}

/** The mock's people: names always (the e2e opt-in plays an accountant). */
export function mockHrPeople(store = mockStore()) {
  mockGate(store)
  const list = mockRead(store, HR_PEOPLE_MOCK_KEY)
  return { people: Array.isArray(list) ? list : [], names: true }
}

/** The mock's person create: 409 on a taken code. */
export function mockHrPersonCreate(body, store = mockStore(), now = new Date()) {
  mockGate(store)
  const list = mockRead(store, HR_PEOPLE_MOCK_KEY)
  const people = Array.isArray(list) ? list : []
  if (people.some((p) => p.code === body.code)) throw mockError(409, 'code_taken', 'a person already has code ' + body.code)
  const p = { ...body, id: 'mock-person-' + now.getTime().toString(36) + '-' + people.length, created_by: 'HUM-1', created_at: now.toISOString() }
  mockWrite(store, HR_PEOPLE_MOCK_KEY, [...people, p])
  return p
}

/** The mock's month state: the rule, unless the mock reopened or closed it. */
export function mockHrPeriod(month, store = mockStore(), now = new Date()) {
  mockGate(store)
  const set = mockRead(store, HR_PERIODS_MOCK_KEY)
  const own = set && !Array.isArray(set) ? set[month] : undefined
  return { period: month, closed: own ? own.closed : hrClosedByRule(month, now), closes_at: hrCloseDay(month) + 'T00:00:00+02:00', reopen_reason: own ? str(own.reason) : '' }
}

/** The mock's close or reopen. */
export function mockHrPeriodSet(month, op, reason, store = mockStore(), now = new Date()) {
  mockGate(store)
  if (op === 'reopen' && !str(reason).trim()) throw mockError(400, 'bad_cost_period', 'a reopen needs a reason of 1..500 characters')
  const set = mockRead(store, HR_PERIODS_MOCK_KEY)
  const next = { ...(set && !Array.isArray(set) ? set : {}), [month]: { closed: op === 'close', reason: op === 'reopen' ? reason : '' } }
  mockWrite(store, HR_PERIODS_MOCK_KEY, next)
  return mockHrPeriod(month, store, now)
}

/* ---- SPL-5433 step c (spec 123 16.4; owner poll 2ff12c21 answer 4 B): the
   employer side computed from the year's rates, over the hub's
   /v1/operator/hr-rates and /hr-payroll/{month} (fleetPaid 'hr_rate*',
   'hr_payroll*'). A typed payslip line wins, a difference is flagged; Book
   writes the computed amounts as lines so the cost reports carry them. ---- */

const HR_RATES_MOCK_KEY = 'spool.mock.hr_rates'
/* the cost entries' mock rows (cost-entries.mjs COST_ENTRIES_MOCK_KEY), read by name: no import across the lazy cards */
const COST_ENTRIES_MOCK_KEY = 'spool.mock.cost_entries'
const GROSS_GROUPS = Object.freeze(['salaries_wages', 'working_time_allowances', 'bonuses_incentives', 'leave_absence'])
const COMPUTED_SOURCE = 'computed:'
const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : 0)
const numOrNull = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null)
const cents = (v) => Math.round(v * 100) / 100

/** The components a rate may be set for: the employer contributions, yel aside (the hub's CheckHRRate). */
export function hrRateComponents(components) {
  return (Array.isArray(components) ? components : []).filter((c) => c && c.group === 'employer_contributions' && c.component !== 'yel')
}

/** The hub's rates ({year, rates}). */
export function hrRatesOf(body) {
  const b = body && typeof body === 'object' ? body : {}
  const list = Array.isArray(b.rates) ? b.rates : []
  return {
    year: Number.isInteger(b.year) ? b.year : null,
    rates: list.filter((r) => r && str(r.component)).map((r) => ({
      component: str(r.component),
      ratePct: num(r.rate_pct),
      appliesTo: Array.isArray(r.applies_to) ? r.applies_to.filter((x) => HR_EMPLOYMENT_TYPES.includes(x)) : [],
      source: str(r.source),
      setBy: str(r.set_by),
    })).sort((a, b2) => a.component.localeCompare(b2.component)),
  }
}

/** A blank rate form. */
export function emptyHrRateForm() {
  return { component: '', ratePct: '', appliesTo: ['employee', 'hourly'], source: '' }
}

/** The first thing wrong with a rate form, as an i18n key suffix ('' = fine); the hub's rdb 0284 CHECKs. */
export function checkHrRateForm(f, components = []) {
  if (!hrRateComponents(components).some((c) => c.component === f.component)) return 'err_rate_component'
  const v = typeof f.ratePct === 'number' ? f.ratePct : Number(String(f.ratePct).replace(',', '.').trim())
  if (String(f.ratePct).trim() === '' || !Number.isFinite(v) || v < 0 || v >= 100 || Math.abs(v * 1e4 - Math.round(v * 1e4)) > 1e-6) return 'err_rate_pct'
  const types = Array.isArray(f.appliesTo) ? f.appliesTo : []
  if (!types.length || types.some((x) => !HR_EMPLOYMENT_TYPES.includes(x))) return 'err_rate_types'
  if (bytes(str(f.source)) > 200) return 'err_rate_source'
  return ''
}

/** The PUT body of a checked rate form. */
export function hrRateBody(f) {
  const v = typeof f.ratePct === 'number' ? f.ratePct : Number(String(f.ratePct).replace(',', '.').trim())
  return { rate_pct: v, applies_to: HR_EMPLOYMENT_TYPES.filter((x) => f.appliesTo.includes(x)), source: str(f.source).trim() }
}

function payrollLineOf(l) {
  const flag = l.flag === 'diff' || l.flag === 'stale' ? l.flag : ''
  return {
    component: str(l.component), ratePct: numOrNull(l.rate_pct), computed: num(l.computed), typed: numOrNull(l.typed),
    booked: numOrNull(l.booked), amount: num(l.amount), diff: num(l.diff), flag,
  }
}

/** The hub's payroll of a month: people (codes, never names), totals per currency, flags, what Book would write. */
export function hrPayrollOf(body) {
  const b = body && typeof body === 'object' ? body : {}
  const people = (Array.isArray(b.people) ? b.people : []).filter((r) => r && str(r.person_id)).map((r) => ({
    personId: str(r.person_id), code: str(r.code), employmentType: str(r.employment_type), currency: str(r.currency),
    gross: num(r.gross), employer: (Array.isArray(r.employer) ? r.employer : []).filter((l) => l && str(l.component)).map(payrollLineOf),
    employerTotal: num(r.employer_total), other: num(r.other), cost: num(r.cost), flags: num(r.flags),
  }))
  const totals = (Array.isArray(b.totals) ? b.totals : []).filter((t) => t && str(t.currency)).map((t) => ({
    currency: str(t.currency), gross: num(t.gross), employerTotal: num(t.employer_total), other: num(t.other), cost: num(t.cost), toBook: num(t.to_book),
  }))
  const stale = people.reduce((n, r) => n + r.employer.filter((l) => l.flag === 'stale').length, 0)
  const period = b.period && typeof b.period === 'object' ? b.period : {}
  return {
    month: MONTH_RE.test(str(b.month)) ? b.month : '',
    people, totals, flags: num(b.flags),
    toBook: totals.reduce((n, t) => n + t.toBook, 0) + stale,
    closed: period.closed === true,
  }
}

/** A person's contribution line as words: its own i18n key and values (the card renders it). */
export function hrPayrollLineNote(l) {
  if (l.flag === 'diff') return { key: 'diff', amount: Math.abs(l.diff) }
  if (l.flag === 'stale') return { key: 'stale', amount: l.computed }
  if (l.typed !== null) return { key: 'typed', amount: l.typed }
  if (l.booked !== null) return { key: 'booked', amount: l.booked }
  if (l.ratePct === null) return { key: 'no_rate', amount: 0 }
  return { key: 'computed', amount: l.computed }
}

function mockRates(store) {
  const v = mockRead(store, HR_RATES_MOCK_KEY)
  return v && !Array.isArray(v) ? v : {}
}

/** The mock's rates of a year. */
export function mockHrRates(year, store = mockStore()) {
  mockGate(store)
  const y = Number(year)
  return { year: y, rates: Object.values(mockRates(store)).filter((r) => r.year === y) }
}

/** The mock's rate set: the hub's checks, yel and pay components refused. */
export function mockHrRateSet(year, component, body, store = mockStore(), now = new Date()) {
  mockGate(store)
  const comps = hrRateComponents(mockHrComponents(store).components)
  const why = checkHrRateForm({ component, ratePct: body && body.rate_pct, appliesTo: (body && body.applies_to) || [], source: (body && body.source) || '' }, comps)
  if (why) throw mockError(400, 'bad_hr_rate', why)
  const r = { year: Number(year), component, rate_pct: body.rate_pct, applies_to: body.applies_to, source: str(body.source), set_by: 'HUM-1', set_at: now.toISOString() }
  mockWrite(store, HR_RATES_MOCK_KEY, { ...mockRates(store), [year + '/' + component]: r })
  return r
}

/** The mock's rate delete: 404 when none. */
export function mockHrRateDelete(year, component, store = mockStore()) {
  mockGate(store)
  const all = mockRates(store)
  const k = year + '/' + component
  if (!all[k]) throw mockError(404, 'not_found', 'no ' + component + ' rate for ' + year)
  const { [k]: _gone, ...rest } = all
  mockWrite(store, HR_RATES_MOCK_KEY, rest)
  return null
}

/** One contribution of the mock's payroll: computed at pct (undefined = no rate), the typed value winning, a booked one going stale (store.ComputeHRPayroll). */
function mockPayrollLine(c, pct, gross, a) {
  const l = { component: c, computed: pct === undefined ? 0 : cents(gross * pct / 100), diff: 0 }
  if (pct !== undefined) l.rate_pct = pct
  l.amount = l.computed
  const typed = a.typed[c] !== undefined
  const own = typed ? a.typed[c] : a.booked[c]
  if (own === undefined) return l
  l.amount = cents(own)
  if (typed) l.typed = l.amount
  else l.booked = l.amount
  if (pct !== undefined) l.diff = cents(l.amount - l.computed)
  const off = Math.abs(l.diff) > 0.011
  if (typed && pct !== undefined && off) l.flag = 'diff'
  if (!typed && (pct === undefined || off)) l.flag = 'stale'
  return l
}

/** The mock's payroll: the hub's calculation over the mock's lines, people and rates (the e2e's, made-up). */
export function mockHrPayroll(month, store = mockStore(), now = new Date()) {
  mockGate(store)
  const groups = Object.fromEntries(mockHrComponents(store).components.map((c) => [c.component, c.group]))
  const people = Object.fromEntries(mockHrPeople(store).people.map((p) => [p.id, p]))
  const rates = mockHrRates(String(month).slice(0, 4), store).rates
  const lines = mockRead(store, COST_ENTRIES_MOCK_KEY)
  const acc = {}
  for (const e of Array.isArray(lines) ? lines : []) {
    if (!e || e.type !== 'hr' || e.period !== month || e.period_kind === 'year' || !people[e.person_id]) continue
    const k = e.person_id + '|' + e.currency
    const a = acc[k] || (acc[k] = { person: people[e.person_id], currency: e.currency, gross: 0, other: 0, typed: {}, booked: {} })
    const g = groups[e.component]
    if (GROSS_GROUPS.includes(g)) a.gross += num(e.amount)
    else if (g === 'employer_contributions') {
      const into = str(e.source).startsWith(COMPUTED_SOURCE) ? a.booked : a.typed
      into[e.component] = (into[e.component] || 0) + num(e.amount)
    } else a.other += num(e.amount)
  }
  const out = { month, people: [], totals: [], flags: 0, period: mockHrPeriod(month, store, now) }
  const totals = {}
  for (const a of Object.values(acc).sort((x, y) => x.person.code.localeCompare(y.person.code))) {
    const gross = cents(a.gross)
    const comps = new Set([...Object.keys(a.typed), ...Object.keys(a.booked)])
    const rated = {}
    for (const r of rates) if (r.applies_to.includes(a.person.employment_type)) { rated[r.component] = r.rate_pct; comps.add(r.component) }
    const t = totals[a.currency] || (totals[a.currency] = { currency: a.currency, gross: 0, employer_total: 0, other: 0, cost: 0, to_book: 0 })
    const row = { person_id: a.person.id, code: a.person.code, employment_type: a.person.employment_type, currency: a.currency, gross, other: cents(a.other), employer: [], employer_total: 0, flags: 0 }
    for (const c of [...comps].sort()) {
      const l = mockPayrollLine(c, rated[c], gross, a)
      if (l.typed === undefined && l.booked === undefined && l.computed > 0) t.to_book++
      if (l.flag) row.flags++
      row.employer_total = cents(row.employer_total + l.amount)
      row.employer.push(l)
    }
    row.cost = cents(row.gross + row.employer_total + row.other)
    t.gross = cents(t.gross + row.gross); t.employer_total = cents(t.employer_total + row.employer_total)
    t.other = cents(t.other + row.other); t.cost = cents(t.cost + row.cost)
    out.flags += row.flags
    out.people.push(row)
  }
  out.totals = Object.values(totals).sort((x, y) => x.currency.localeCompare(y.currency))
  return out
}

/** The mock's book: removes the stale booked lines, writes the computed amounts; 409 in a closed month. */
export function mockHrPayrollBook(month, store = mockStore(), now = new Date()) {
  mockGate(store)
  if (mockHrPeriod(month, store, now).closed) throw mockError(409, 'month_closed', 'the month ' + month + ' is closed')
  const p = mockHrPayroll(month, store, now)
  const labels = Object.fromEntries(mockHrComponents(store).components.map((c) => [c.component, c.label]))
  const redo = []
  const add = []
  for (const r of p.people) {
    for (const l of r.employer) {
      if (l.flag === 'stale') redo.push(r.person_id + '|' + l.component + '|' + r.currency)
      if (l.typed === undefined && l.rate_pct !== undefined && l.computed > 0 && (l.booked === undefined || l.flag === 'stale')) add.push({ r, l })
    }
  }
  const lines = mockRead(store, COST_ENTRIES_MOCK_KEY)
  const keep = (Array.isArray(lines) ? lines : []).filter((e) => !(e && e.type === 'hr' && e.period === month && str(e.source).startsWith(COMPUTED_SOURCE)
    && redo.includes(e.person_id + '|' + e.component + '|' + e.currency)))
  const removed = (Array.isArray(lines) ? lines.length : 0) - keep.length
  add.forEach(({ r, l }, i) => keep.push({
    id: 'mock-booked-' + now.getTime().toString(36) + '-' + i, type: 'hr', label: labels[l.component] || l.component, amount: l.computed, currency: r.currency,
    period: month, note: '', created_by: 'HUM-1', created_at: now.toISOString(), person_id: r.person_id, component: l.component,
    source: COMPUTED_SOURCE + ' ' + month.slice(0, 4) + ' rates', account: '', period_kind: 'month', corrects_period: '',
  }))
  mockWrite(store, COST_ENTRIES_MOCK_KEY, keep)
  return { booked: add.length, removed, payroll: mockHrPayroll(month, store, now) }
}
