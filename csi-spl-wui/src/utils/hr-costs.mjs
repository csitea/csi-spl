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
    c('tyel_employer', 'employer_contributions', "TyEL, employer's share"), c('overtime', 'working_time_allowances', 'Overtime'),
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
