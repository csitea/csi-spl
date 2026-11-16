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
  /* the mock plays an accountant (names: true), so its payroll carries the worker side (step d) */
  out.worker = mockHrWorker(out, store)
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

/* ---- SPL-5433 step d (spec 123 16.5; owner poll 2ff12c21 answer 4 B): the
   worker side, over the hub's /v1/operator/hr-worker-rates, /hr-tax-cards,
   /hr-payslips and the payroll's "worker" (fleetPaid 'hr_worker_rates*',
   'hr_tax_card*', 'hr_payslip*'). The employee's shares by age band, the tax
   from the year's card over the year-to-date gross, the net, each checked
   against the payslip. A costs.write member's only; never in a total. ---- */

export const HR_WORKER_KINDS = Object.freeze(['tyel_employee', 'unemployment_employee'])
const HR_WORKER_TYPES = Object.freeze(['employee', 'hourly'])
const HR_TAXED_TYPES = Object.freeze(['employee', 'hourly', 'owner_management'])
export const HR_PAYSLIP_FIELDS = Object.freeze(['tyel_employee', 'unemployment_employee', 'tax_withheld', 'net_pay'])
const HR_WORKER_RATES_MOCK_KEY = 'spool.mock.hr_worker_rates'
const HR_TAX_CARDS_MOCK_KEY = 'spool.mock.hr_tax_cards'
const HR_PAYSLIPS_MOCK_KEY = 'spool.mock.hr_payslips'
const CURRENCY_RE = /^[A-Z]{3}$/

/* a typed decimal ("12,5" or "12.5"), NaN when not a number, null when empty */
const decimalOf = (v) => {
  if (typeof v === 'number') return v
  const s = String(v ?? '').replace(',', '.').trim()
  return s === '' ? null : Number(s)
}
const decimals = (v, n) => Math.abs(v * 10 ** n - Math.round(v * 10 ** n)) <= 1e-6

function workerLineOf(l) {
  return {
    kind: str(l && l.kind), ratePct: numOrNull(l && l.rate_pct), computed: num(l && l.computed), typed: numOrNull(l && l.typed),
    amount: num(l && l.amount), diff: num(l && l.diff), flag: l && l.flag === 'diff' ? 'diff' : '',
  }
}

/** The payroll's worker side (a costs.write reader's only; [] when the hub sent none). */
export function hrWorkerOf(body) {
  const b = body && typeof body === 'object' ? body : {}
  return (Array.isArray(b.worker) ? b.worker : []).filter((w) => w && str(w.person_id)).map((w) => {
    const c = w.tax_card && typeof w.tax_card === 'object' ? w.tax_card : null
    return {
      personId: str(w.person_id), code: str(w.code), currency: str(w.currency), age: num(w.age), gross: num(w.gross),
      ytdBefore: num(w.ytd_before), ytd: num(w.ytd),
      taxCard: c ? { basePct: num(c.base_pct), extraPct: num(c.extra_pct), incomeLimit: num(c.income_limit) } : null,
      shares: (Array.isArray(w.shares) ? w.shares : []).map(workerLineOf), tax: workerLineOf(w.tax), net: workerLineOf(w.net),
      missing: (Array.isArray(w.missing) ? w.missing : []).filter((m) => m === 'tax_card' || m === 'birth_year'),
      flags: num(w.flags),
    }
  })
}

/** A worker-side value as words: its own i18n key and amount (the card renders it). */
export function hrWorkerLineNote(l) {
  if (l.flag === 'diff') return { key: 'diff', amount: Math.abs(l.diff) }
  if (l.typed !== null) return { key: 'typed', amount: l.typed }
  return { key: 'computed', amount: l.computed }
}

/** The hub's worker-share bands ({year, rates}), by kind then age. */
export function hrWorkerRatesOf(body) {
  const b = body && typeof body === 'object' ? body : {}
  return (Array.isArray(b.rates) ? b.rates : []).filter((r) => r && HR_WORKER_KINDS.includes(r.kind)).map((r) => ({
    kind: r.kind, ageFrom: num(r.age_from), ageTo: num(r.age_to), ratePct: num(r.rate_pct), source: str(r.source),
  })).sort((x, y) => x.kind.localeCompare(y.kind) || x.ageFrom - y.ageFrom)
}

/** The hub's tax cards ({year, tax_cards}). */
export function hrTaxCardsOf(body) {
  const b = body && typeof body === 'object' ? body : {}
  return (Array.isArray(b.tax_cards) ? b.tax_cards : []).filter((c) => c && str(c.person_id)).map((c) => ({
    personId: str(c.person_id), basePct: num(c.base_pct), extraPct: num(c.extra_pct), incomeLimit: num(c.income_limit), source: str(c.source),
  }))
}

/** A blank band form. */
export function emptyHrBandForm() {
  return { kind: 'tyel_employee', ageFrom: '', ageTo: '', ratePct: '', source: '' }
}

/** The bands of kind after adding the form's band to the current ones, or an i18n key suffix of what is wrong (rdb 0286's CHECKs). */
export function hrBandsWith(f, current) {
  if (!HR_WORKER_KINDS.includes(f.kind)) return { problem: 'err_band_kind' }
  const from = decimalOf(f.ageFrom)
  const to = decimalOf(f.ageTo)
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to > 120 || to < from) return { problem: 'err_band_ages' }
  const pct = decimalOf(f.ratePct)
  if (pct === null || !Number.isFinite(pct) || pct < 0 || pct >= 100 || !decimals(pct, 4)) return { problem: 'err_band_pct' }
  if (bytes(str(f.source)) > 200) return { problem: 'err_band_source' }
  const same = (current || []).filter((r) => r.kind === f.kind)
  if (same.some((r) => from <= r.ageTo && to >= r.ageFrom)) return { problem: 'err_band_overlap' }
  if (same.length >= 10) return { problem: 'err_band_many' }
  const bands = [...same.map((r) => ({ age_from: r.ageFrom, age_to: r.ageTo, rate_pct: r.ratePct })), { age_from: from, age_to: to, rate_pct: pct }]
  bands.sort((x, y) => x.age_from - y.age_from)
  return { problem: '', bands }
}

/** A blank tax card form. */
export function emptyHrTaxCardForm() {
  return { personId: '', basePct: '', extraPct: '', incomeLimit: '', source: '' }
}

/** The first thing wrong with a tax card form, as an i18n key suffix ('' = fine). */
export function checkHrTaxCardForm(f) {
  if (!str(f.personId)) return 'err_card_person'
  for (const [k, why] of [['basePct', 'err_card_base'], ['extraPct', 'err_card_extra']]) {
    const v = decimalOf(f[k])
    if (v === null || !Number.isFinite(v) || v < 0 || v >= 100 || !decimals(v, 2)) return why
  }
  const lim = decimalOf(f.incomeLimit)
  if (lim === null || !Number.isFinite(lim) || lim < 0 || lim >= 1e10 || !decimals(lim, 2)) return 'err_card_limit'
  if (bytes(str(f.source)) > 200) return 'err_card_source'
  return ''
}

/** The PUT body of a checked tax card form. */
export function hrTaxCardBody(f) {
  return { base_pct: decimalOf(f.basePct), extra_pct: decimalOf(f.extraPct), income_limit: decimalOf(f.incomeLimit), source: str(f.source).trim() }
}

/** A blank payslip form. */
export function emptyHrPayslipForm() {
  return { personId: '', currency: 'EUR', tyel_employee: '', unemployment_employee: '', tax_withheld: '', net_pay: '' }
}

/** The first thing wrong with a payslip form, as an i18n key suffix ('' = fine). */
export function checkHrPayslipForm(f) {
  if (!str(f.personId)) return 'err_slip_person'
  if (!CURRENCY_RE.test(str(f.currency))) return 'err_slip_currency'
  let any = false
  for (const k of HR_PAYSLIP_FIELDS) {
    const v = decimalOf(f[k])
    if (v === null) continue
    any = true
    if (!Number.isFinite(v) || Math.abs(v) >= 1e10 || !decimals(v, 2) || (v < 0 && k !== 'net_pay')) return 'err_slip_amount'
  }
  return any ? '' : 'err_slip_empty'
}

/** The PUT body of a checked payslip form: the values typed, nothing for the empty ones. */
export function hrPayslipBody(f) {
  const out = { currency: f.currency }
  for (const k of HR_PAYSLIP_FIELDS) {
    const v = decimalOf(f[k])
    if (v !== null) out[k] = v
  }
  return out
}

function mockMap(store, key) {
  const v = mockRead(store, key)
  return v && !Array.isArray(v) ? v : {}
}

/** The mock's bands of a year. */
export function mockHrWorkerRates(year, store = mockStore()) {
  mockGate(store)
  const y = Number(year)
  return { year: y, rates: Object.values(mockMap(store, HR_WORKER_RATES_MOCK_KEY)).flat().filter((r) => r.year === y) }
}

/** The mock's bands set: replaces the year's bands of kind. */
export function mockHrWorkerRatesSet(year, body, store = mockStore(), now = new Date()) {
  mockGate(store)
  const kind = body && body.kind
  if (!HR_WORKER_KINDS.includes(kind)) throw mockError(400, 'bad_hr_worker_rate', 'kind must be tyel_employee or unemployment_employee')
  const rates = ((body && body.bands) || []).map((b) => ({ year: Number(year), kind, age_from: b.age_from, age_to: b.age_to, rate_pct: b.rate_pct,
    source: str(body.source), set_by: 'HUM-1', set_at: now.toISOString() }))
  mockWrite(store, HR_WORKER_RATES_MOCK_KEY, { ...mockMap(store, HR_WORKER_RATES_MOCK_KEY), [year + '/' + kind]: rates })
  return { year: Number(year), kind, rates }
}

/** The mock's tax cards of a year. */
export function mockHrTaxCards(year, store = mockStore()) {
  mockGate(store)
  const y = Number(year)
  return { year: y, tax_cards: Object.values(mockMap(store, HR_TAX_CARDS_MOCK_KEY)).filter((c) => c.year === y) }
}

/** The mock's tax card set: 404 for no such person, the form's checks. */
export function mockHrTaxCardSet(year, body, store = mockStore(), now = new Date()) {
  mockGate(store)
  const pid = str(body && body.person_id)
  if (!mockHrPeople(store).people.some((p) => p.id === pid)) throw mockError(404, 'not_found', 'no such person')
  const why = checkHrTaxCardForm({ personId: pid, basePct: body.base_pct, extraPct: body.extra_pct, incomeLimit: body.income_limit, source: body.source })
  if (why) throw mockError(400, 'bad_hr_tax_card', why)
  const c = { person_id: pid, year: Number(year), base_pct: body.base_pct, extra_pct: body.extra_pct, income_limit: body.income_limit,
    source: str(body.source), set_by: 'HUM-1', set_at: now.toISOString() }
  mockWrite(store, HR_TAX_CARDS_MOCK_KEY, { ...mockMap(store, HR_TAX_CARDS_MOCK_KEY), [pid + '/' + year]: c })
  return c
}

/** The mock's tax card delete: 404 when none. */
export function mockHrTaxCardDelete(year, personId, store = mockStore()) {
  mockGate(store)
  const all = mockMap(store, HR_TAX_CARDS_MOCK_KEY)
  const k = personId + '/' + year
  if (!all[k]) throw mockError(404, 'not_found', 'no tax card for that person and ' + year)
  const { [k]: _gone, ...rest } = all
  mockWrite(store, HR_TAX_CARDS_MOCK_KEY, rest)
  return null
}

/** The mock's payslip set: 404 for no such person, 409 in a closed month. */
export function mockHrPayslipSet(month, body, store = mockStore(), now = new Date()) {
  mockGate(store)
  const pid = str(body && body.person_id)
  if (!mockHrPeople(store).people.some((p) => p.id === pid)) throw mockError(404, 'not_found', 'no such person')
  const why = checkHrPayslipForm({ personId: pid, ...body })
  if (why) throw mockError(400, 'bad_hr_payslip', why)
  if (mockHrPeriod(month, store, now).closed) throw mockError(409, 'month_closed', 'the month ' + month + ' is closed')
  const s = { person_id: pid, month, ...hrPayslipBody({ ...body }), set_by: 'HUM-1', set_at: now.toISOString() }
  mockWrite(store, HR_PAYSLIPS_MOCK_KEY, { ...mockMap(store, HR_PAYSLIPS_MOCK_KEY), [pid + '/' + month + '/' + s.currency]: s })
  return s
}

/** The mock's payslip delete: 404 when none, 409 in a closed month. */
export function mockHrPayslipDelete(month, body, store = mockStore(), now = new Date()) {
  mockGate(store)
  if (mockHrPeriod(month, store, now).closed) throw mockError(409, 'month_closed', 'the month ' + month + ' is closed')
  const all = mockMap(store, HR_PAYSLIPS_MOCK_KEY)
  const k = str(body && body.person_id) + '/' + month + '/' + (str(body && body.currency) || 'EUR')
  if (!all[k]) throw mockError(404, 'not_found', 'no payslip for that person, month and currency')
  const { [k]: _gone, ...rest } = all
  mockWrite(store, HR_PAYSLIPS_MOCK_KEY, rest)
  return null
}

/** One checked worker-side value: the payslip's typed value wins, a difference above a cent is flagged. */
function mockWorkerLine(kind, computed, typed, pct) {
  const l = { kind, computed, amount: computed, diff: 0 }
  if (pct !== undefined) l.rate_pct = pct
  if (typeof typed === 'number') {
    l.typed = cents(typed)
    l.amount = l.typed
    l.diff = cents(l.typed - computed)
    if (Math.abs(l.diff) > 0.011) l.flag = 'diff'
  }
  return l
}

/** The mock's worker side of a payroll (store.ComputeHRWorker over the mock's rows). */
function mockHrWorker(payroll, store = mockStore()) {
  const month = payroll.month
  const year = Number(String(month).slice(0, 4))
  const groups = Object.fromEntries(mockHrComponents(store).components.map((c) => [c.component, c.group]))
  const people = Object.fromEntries(mockHrPeople(store).people.map((p) => [p.id, p]))
  const bands = mockHrWorkerRates(year, store).rates
  const cards = Object.fromEntries(mockHrTaxCards(year, store).tax_cards.map((c) => [c.person_id, c]))
  const slips = mockMap(store, HR_PAYSLIPS_MOCK_KEY)
  const lines = mockRead(store, COST_ENTRIES_MOCK_KEY)
  const ytd = {}
  for (const e of Array.isArray(lines) ? lines : []) {
    if (!e || e.type !== 'hr' || e.period_kind === 'year' || e.period < year + '-01' || e.period >= month || !GROSS_GROUPS.includes(groups[e.component])) continue
    const k = e.person_id + '|' + e.currency
    ytd[k] = cents((ytd[k] || 0) + num(e.amount))
  }
  return payroll.people.map((row) => {
    const person = people[row.person_id] || {}
    const slip = slips[row.person_id + '/' + month + '/' + row.currency] || {}
    const before = ytd[row.person_id + '|' + row.currency] || 0
    const age = Number(person.birth_year) > 0 ? year - Number(person.birth_year) : 0
    const w = { person_id: row.person_id, code: row.code, currency: row.currency, gross: row.gross, ytd_before: before, ytd: cents(before + row.gross), shares: [], missing: [], flags: 0 }
    if (age) w.age = age
    let shares = 0
    if (HR_WORKER_TYPES.includes(row.employment_type)) {
      for (const kind of HR_WORKER_KINDS) {
        const of = bands.filter((b) => b.kind === kind)
        if (!of.length) continue
        const band = age ? of.find((b) => age >= b.age_from && age <= b.age_to) : undefined
        if (!age && !w.missing.includes('birth_year')) w.missing.push('birth_year')
        const l = mockWorkerLine(kind, band ? cents(row.gross * band.rate_pct / 100) : 0, slip[kind], band ? band.rate_pct : undefined)
        shares += l.amount
        w.shares.push(l)
      }
    }
    let tax = 0
    const card = cards[row.person_id]
    if (HR_TAXED_TYPES.includes(row.employment_type)) {
      if (card) {
        w.tax_card = card
        const under = Math.max(0, Math.min(row.gross, card.income_limit - before))
        tax = cents(under * card.base_pct / 100 + (row.gross - under) * card.extra_pct / 100)
      } else w.missing.push('tax_card')
    }
    w.tax = mockWorkerLine('tax_withheld', tax, slip.tax_withheld)
    w.net = mockWorkerLine('net_pay', cents(row.gross - shares - w.tax.amount), slip.net_pay)
    w.flags = [...w.shares, w.tax, w.net].filter((l) => l.flag).length
    return w
  })
}
