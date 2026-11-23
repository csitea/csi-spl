// csi-spl-wui/src/utils/cost-project.mjs
//
// Spec 123 section 13, row P05 (SPL-6117; owner HUM-10, t1 e2c0e6b4, msgs
// 3a190b70 "These the costs of this project" and 143a0a1c "the importance is
// to be able to see the monthly and yearly costs"): the page
// /reporting/costs/project over GET /v1/tenant/costs/project (row P01, the
// Human mask row P03, csi-spl-api hub/cost_project.go). One answer per
// period: ?month=YYYY-MM (none = the current month so far) or ?year=YYYY
// (January to now, the closed months and the month so far). Its parts:
// Cloud, Owned hardware, AI tokens and Human for the operator workspace's
// estate read; AI tokens and Human for any other workspace (Q-8 A, 13.7).
//
// A part that is not known is null, never 0 (13.5): its cell is a dash and
// it is left out of every sum here, as the hub leaves it out of
// total.priced. Loaded only by the page and the client's mock.

import { storageGet } from './prefs.mjs'
import { COSTS_MOCK_KEY, COSTS_READ, MOCK_FX_RATES } from './tenant-costs.mjs'

/** The parts in the order the page draws them (store/cost_project.go). */
const COST_PROJECT_PARTS = Object.freeze(['cloud', 'owned_hardware', 'ai_tokens', 'human'])

/** The completeness words the hub answers (13.5) and the whole mask's (13.6). */
const COST_PROJECT_DONE = Object.freeze(['complete', 'partial', 'unpriced', 'hand', 'not_tracked', 'not_shown'])

/** The page that holds each part's detail (13.2): Owned hardware's asset
 *  list is the paid items, now under Expenses -> AI costs (SPL-4382). */
export const COST_PROJECT_LINKS = Object.freeze({
  cloud: '/reporting/costs/cloud',
  owned_hardware: '/expenses/ai',
  ai_tokens: '/reporting/costs/tokens',
  human: '/reporting/costs/persons',
})

const MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])$/
const YEAR_RE = /^\d{4}$/
const CUR_RE = /^[A-Z]{3}$/
const str = (v) => (typeof v === 'string' ? v : '')
const int = (v) => (Number.isFinite(Number(v)) ? Math.trunc(Number(v)) : 0)
/** null / missing / non-numeric stays null: an unknown amount is never 0. */
const intOrNull = (v) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Math.trunc(Number(v)))
const numOrNull = (v) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Number(v))
const money = (m) => ({ usd: intOrNull(m?.usd_micros), eur: intOrNull(m?.eur_micros), second: intOrNull(m?.second_micros) })

/**
 * The query of one period: a year, a month range (SPL-6300, both months
 * included), a month, or '' (the current month so far).
 * @param {{ month?: string, year?: string, from?: string, to?: string }} [p]
 */
export function costProjectQuery({ month = '', year = '', from = '', to = '' } = {}) {
  if (YEAR_RE.test(String(year))) return '?year=' + year
  if (MONTH_RE.test(String(from)) && MONTH_RE.test(String(to))) return '?from=' + from + '&to=' + to
  if (MONTH_RE.test(String(month))) return '?month=' + month
  return ''
}

function partOf(p) {
  return {
    part: str(p?.part),
    ...money(p),
    share: numOrNull(p?.share),
    completeness: str(p?.completeness),
    lines: int(p?.lines),
    unpriced: int(p?.unpriced),
    daysRead: intOrNull(p?.days_read),
    days: intOrNull(p?.days),
  }
}

/** The hub's answer, every field typed; an unknown amount or share stays null. @param {any} body */
export function costProjectOf(body) {
  const b = body && typeof body === 'object' ? body : {}
  const parts = (Array.isArray(b.parts) ? b.parts : []).map(partOf).filter((p) => COST_PROJECT_PARTS.includes(p.part))
  parts.sort((a, c) => COST_PROJECT_PARTS.indexOf(a.part) - COST_PROJECT_PARTS.indexOf(c.part))
  return {
    period: b.period === 'year' || b.period === 'range' ? b.period : 'month',
    month: str(b.month),
    monthFrom: str(b.month_from),
    monthTo: str(b.month_to),
    year: str(b.year),
    from: str(b.from),
    to: str(b.to),
    status: str(b.status),
    scope: b.scope === 'estate' ? 'estate' : 'workspace',
    secondCurrency: CUR_RE.test(str(b.second_currency)) ? b.second_currency : '',
    days: int(b.days),
    daysEnded: int(b.days_ended),
    parts,
    total: { ...money(b.total?.priced), partial: b.total?.partial === true },
    leftOut: (Array.isArray(b.left_out) ? b.left_out : []).map((l) => ({
      source: str(l?.source), projectOrVendor: str(l?.project_or_vendor), kind: str(l?.kind),
      usd: int(l?.usd_micros), unpriced: l?.unpriced === true,
    })),
    humanMask: ['money', 'whole'].includes(b.human_mask) ? b.human_mask : 'none',
  }
}

/**
 * An amount (a part or the total) in the header's currency: USD, the
 * answer's second currency, or EUR; null when the hub has none in it.
 * @param {{ usd: number|null, eur: number|null, second: number|null }} m
 * @param {string} currency
 * @param {string} [second] the answer's second currency
 */
export function costProjectAmount(m, currency, second = '') {
  if (!m) return null
  if (currency === 'USD') return m.usd
  if (currency === second) return m.second
  if (currency === 'EUR') return m.eur
  return null
}

/** A part's completeness words: its key under reporting.costs.project.done and its params. */
export function costProjectDoneOf(p) {
  const key = COST_PROJECT_DONE.includes(p?.completeness) ? p.completeness : 'not_tracked'
  if (key === 'partial') return { key, params: { n: p.daysRead ?? 0, total: p.days ?? 0 } }
  if (key === 'unpriced') return { key, params: { n: p.unpriced } }
  return { key, params: {} }
}

/* ---- the mock hub (the e2e and the mock bundle) ---- */

const MOCK_EUR_PER_USD = MOCK_FX_RATES.EUR
const toMicros = (n) => Math.round(n * 1e6)

function mockMonthWindow(month, now) {
  const [y, mo] = month.split('-').map(Number)
  const first = Date.UTC(y, mo - 1, 1)
  const next = Date.UTC(y, mo, 1)
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())
  const days = Math.round((next - first) / 86400000)
  const soFar = today < next
  const ended = soFar ? Math.max(0, Math.round((today - first) / 86400000)) : days
  return { days, ended, soFar, to: new Date(next - 86400000).toISOString().slice(0, 10) }
}

/* one mock month's parts in USD: each month its own figures, so a year that
   left out its closed months reads a different total than their sum */
function mockMonthParts(month, w, estate, human) {
  const i = Number(month.slice(5, 7))
  const cloud = { part: 'cloud', usd: 100 + 10 * i, lines: 3, read: w.soFar ? Math.max(0, w.ended - 1) : w.ended }
  const hw = { part: 'owned_hardware', usd: 0, lines: 0 }
  const ai = { part: 'ai_tokens', usd: (estate ? 300 : 45) + 20 * i, lines: 2, read: w.ended }
  const hu = { part: 'human', usd: human ? 50 + 5 * i : null, lines: human ? 4 : 0 }
  return estate ? [cloud, hw, ai, hu] : [ai, hu]
}

function mockFold(months, estate, human, now) {
  const by = new Map()
  let ended = 0
  let days = 0
  for (const m of months) {
    const w = mockMonthWindow(m, now)
    ended += w.ended
    days += w.days
    for (const p of mockMonthParts(m, w, estate, human)) {
      const s = by.get(p.part) || { part: p.part, usd: p.usd === null ? null : 0, lines: 0, read: p.read === undefined ? undefined : 0 }
      if (p.usd !== null) s.usd += p.usd
      s.lines += p.lines
      if (p.read !== undefined) s.read += p.read
      by.set(p.part, s)
    }
  }
  return { parts: [...by.values()], ended, days }
}

function mockPartBody(s, ended, rate) {
  if (s.usd === null) return { part: s.part, usd_micros: null, eur_micros: null, second_micros: null, share: null, completeness: 'not_tracked', lines: 0, unpriced: 0 }
  const body = {
    part: s.part,
    usd_micros: toMicros(s.usd),
    eur_micros: toMicros(s.usd * MOCK_EUR_PER_USD),
    second_micros: rate || !s.lines ? toMicros(s.usd * rate) : null,
    share: null,
    completeness: s.part === 'owned_hardware' ? 'hand' : 'complete',
    lines: s.lines,
    unpriced: rate ? 0 : s.lines,
  }
  if (s.read !== undefined) {
    Object.assign(body, { days_read: s.read, days: ended })
    if (s.read < ended) body.completeness = 'partial'
  }
  if (!rate && s.lines) body.completeness = 'unpriced'
  return body
}

/* the human mask (13.6) as hub/cost_project.go costProjectHumanMask applies it */
function mockMask(body, mask) {
  if (mask === 'none') return
  for (const p of body.parts) {
    if (p.part !== 'human') continue
    for (const k of ['usd_micros', 'eur_micros', 'second_micros']) {
      if (p[k] !== null && body.total.priced[k] !== null) body.total.priced[k] -= p[k]
      p[k] = null
    }
    if (mask === 'whole') Object.assign(p, { completeness: 'not_shown', lines: 0, unpriced: 0 })
  }
}

function mockShares(body) {
  const t = body.total.priced.usd_micros
  for (const p of body.parts) p.share = p.usd_micros !== null && t > 0 ? Math.round(p.usd_micros * 1000 / t) / 10 : null
}

/** The mock reader's Human mask: hours.rates none, hours.read money, any other listed role whole. */
function mockMaskOf(me) {
  const perms = me && Array.isArray(me.permissions) ? me.permissions : null
  if (!perms || perms.includes('hours.rates')) return 'none'
  return perms.includes('hours.read') ? 'money' : 'whole'
}

function mockMonths(month, year, now, from = '', to = '') {
  const cur = now.toISOString().slice(0, 7)
  if (MONTH_RE.test(String(from)) && MONTH_RE.test(String(to)) && from <= to && !YEAR_RE.test(String(year))) {
    const out = []
    for (let d = new Date(from + '-01T00:00:00Z'); d.toISOString().slice(0, 7) <= to; d.setUTCMonth(d.getUTCMonth() + 1)) out.push(d.toISOString().slice(0, 7))
    return out
  }
  if (!YEAR_RE.test(String(year))) return [MONTH_RE.test(String(month)) ? month : cur]
  const last = year === cur.slice(0, 4) ? Number(cur.slice(5, 7)) : 12
  return Array.from({ length: last }, (_, i) => year + '-' + String(i + 1).padStart(2, '0'))
}

/**
 * The mock GET /v1/tenant/costs/project. Scenarios (localStorage
 * COSTS_MOCK_KEY, as the month read's mock): '' the estate's four parts,
 * Human not tracked yet (null, as P01 answers before P02); 'share' a
 * customer workspace's two parts; 'human' Human priced (as after P02), masked
 * by the mock reader's permissions; 'norate' no rate in the second currency.
 * @param {{ month?: string, year?: string, from?: string, to?: string }} period
 * @param {{ me?: any, now?: Date, scenario?: string, currency?: string }} [o]
 */
export function mockCostProject({ month = '', year = '', from = '', to = '' } = {}, { me = null, now = new Date(), scenario, currency = 'EUR' } = {}) {
  if (me && Array.isArray(me.permissions) && !me.permissions.includes(COSTS_READ)) {
    throw Object.assign(new Error('your role in this tenant does not grant ' + COSTS_READ), { status: 403, code: 'forbidden', permission: COSTS_READ })
  }
  const sc = scenario === undefined ? String(storageGet(COSTS_MOCK_KEY, '') || '') : scenario
  const months = mockMonths(month, year, now, from, to)
  const ranged = !year && months.length > 1
  const estate = sc !== 'share'
  const human = sc === 'human'
  const f = mockFold(months, estate, human, now)
  const parts = f.parts.map((s) => mockPartBody(s, f.ended, sc === 'norate' ? 0 : (MOCK_FX_RATES[currency] || 0)))
  const sum = (k) => parts.reduce((a, p) => (p[k] === null ? a : a + p[k]), 0)
  const last = mockMonthWindow(months[months.length - 1], now)
  const body = {
    period: year ? 'year' : ranged ? 'range' : 'month',
    ...(year ? { year } : { month: months[0] }),
    ...(ranged ? { month_from: months[0], month_to: months[months.length - 1] } : {}),
    from: months[0] + '-01',
    to: last.to,
    status: last.soFar ? 'so_far' : 'ended',
    scope: estate ? 'estate' : 'workspace',
    second_currency: currency,
    days: f.days,
    days_ended: f.ended,
    parts,
    total: { priced: { usd_micros: sum('usd_micros'), eur_micros: sum('eur_micros'), second_micros: sum('second_micros') },
      partial: parts.some((p) => p.completeness !== 'complete' && p.completeness !== 'hand') },
    left_out: [],
  }
  const mask = human ? mockMaskOf(me) : 'none'
  mockMask(body, mask)
  mockShares(body)
  return { ...body, human_mask: mask }
}
