/**
 * Spec 123 sections 5 and 5.2 (SPL-2056, owner HUM-10, t1 dbf2f39b): the
 * Monitoring -> Costs tab over GET /v1/tenant/costs?month=YYYY-MM (hub
 * internal/hub/cost_read.go). The month body, its money in USD and EUR from
 * micros, the pie's slices, the "n of N days complete" per source and the
 * honest empties ("no cost data yet for <source>", never a 0 pie).
 * Spec 123 5.4 (SPL-2108/2199): the second-currency column, each amount in
 * the reader's own pick (EUR unless picked) with the rate and its date, and
 * the picker's list (GET /v1/tenant/fx/currencies).
 *
 * Only the costs page, its pie and the lazy spool client import this file,
 * so none of it rides the initial JS (ci_initial_gzip_kb). Node tests import
 * it.
 */

import { storageGet } from './prefs.mjs'

/** The permission the hub checks (rbac.CostsRead); its 403 names it. */
export const COSTS_READ = 'costs.read'
/** e2e opt-in (mock only): '' = a full estate month, 'empty' = today's prd (counts only, no GCP). */
export const COSTS_MOCK_KEY = 'spool.mock.costs'
/** A part at or under this share of the month (%) folds into the pie's "other". */
const COST_PIE_MIN_PCT = 1
/** The months the picker offers, the current one first. */
const COST_MONTHS_BACK = 12

/** The second currency when the person never picked one (the hub's store.DefaultSecondCurrency). */
export const COST_SECOND_DEFAULT = 'EUR'

const MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])$/
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/
const CUR_RE = /^[A-Z]{3}$/
const int = (v) => (Number.isFinite(Number(v)) ? Math.trunc(Number(v)) : 0)
const str = (v) => (typeof v === 'string' ? v : '')
/** null / a missing or non-numeric value stays null (no rate is never a 0). */
const intOrNull = (v) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Math.trunc(Number(v)))
const day = (v) => (typeof v === 'string' && DAY_RE.test(v.slice(0, 10)) ? v.slice(0, 10) : '')

/** An ISO 4217 code, upper-cased; anything else ''. */
export function costCurrency(v) {
  const c = String(v ?? '').trim().toUpperCase()
  return CUR_RE.test(c) ? c : ''
}

/** The query of one month ('' = the hub's default, the current month so far). */
export function costsQuery(month = '') {
  return MONTH_RE.test(String(month)) ? '?month=' + month : ''
}

/** micros -> "$1,234.56" / "1 234,56 €" in the reader's locale; '' for a missing amount. */
export function costMoney(micros, currency = 'USD', locale = 'en') {
  if (micros === null || micros === undefined || micros === '' || !Number.isFinite(Number(micros))) return ''
  const v = Number(micros) / 1e6
  try {
    return new Intl.NumberFormat(locale, { style: 'currency', currency, minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(v)
  } catch {
    return v.toFixed(2) + ' ' + currency
  }
}

/** A unit count, compact ("2.6B", "910K"); '' for none. */
export function costUnits(units, locale = 'en') {
  const n = Number(units)
  if (!Number.isFinite(n) || n <= 0) return ''
  try {
    return new Intl.NumberFormat(locale, { notation: 'compact', maximumFractionDigits: 1 }).format(n)
  } catch {
    return String(Math.round(n))
  }
}

/** A part's own key: (estate, source, project_or_vendor, kind, origin), the hub's GROUP BY. */
export function costPartKey(p) {
  return [p.estate ? 'e' : 'w', p.source, p.projectOrVendor, p.kind, p.origin].join('|')
}

function costPartOf(p) {
  const r = p && typeof p === 'object' ? p : {}
  const list = r.list_value_micros === null || r.list_value_micros === undefined ? 0 : int(r.list_value_micros)
  return {
    estate: r.estate === true,
    source: str(r.source),
    projectOrVendor: str(r.project_or_vendor),
    kind: str(r.kind),
    origin: str(r.origin),
    units: Number.isFinite(Number(r.units)) ? Number(r.units) : 0,
    usdMicros: int(r.usd_micros),
    eurMicros: int(r.eur_micros),
    listValueMicros: list > 0 ? list : null,
    days: int(r.days),
    hand: r.hand === true,
    pct: typeof r.pct === 'number' && Number.isFinite(r.pct) ? r.pct : null,
    ...costSecondOf(r),
  }
}

/* spec 123 5.4: the part's second-currency amount, the latest day's rate and
   the rate dates; all null when a cost day had no rate (never a guess) */
function costSecondOf(r) {
  const micros = intOrNull(r.second_micros)
  const rate = Number(r.fx_rate)
  const ok = micros !== null && r.fx_rate !== null && r.fx_rate !== undefined && Number.isFinite(rate) && rate > 0 && day(r.fx_rate_day) !== ''
  return {
    secondMicros: ok ? micros : null,
    fxRate: ok ? rate : null,
    fxRateDay: ok ? day(r.fx_rate_day) : '',
    fxRateFirstDay: ok ? day(r.fx_rate_first_day) || day(r.fx_rate_day) : '',
  }
}

/* spec 140 3.10 (SPL-3565): one (workspace, vendor) of the estate's token burn, the operator admin's only */
function costWorkspaceOf(w) {
  const r = w && typeof w === 'object' ? w : {}
  return {
    workspace: str(r.workspace),
    vendor: str(r.vendor),
    tokens: int(r.tokens),
    listValueMicros: int(r.list_value_micros),
    days: int(r.days),
  }
}

/** The month's list-price total (USD micros): every part's list value, 0 for none (spec 140 3.10). */
export function costListTotal(parts) {
  return (Array.isArray(parts) ? parts : []).reduce((s, p) => s + (p && p.listValueMicros ? p.listValueMicros : 0), 0)
}

function costCoverageOf(c) {
  const r = c && typeof c === 'object' ? c : {}
  return {
    source: str(r.source),
    ok: int(r.ok),
    partial: int(r.partial),
    missing: int(r.missing),
    unrecorded: int(r.unrecorded),
    days: int(r.days),
  }
}

/** The hub's month body -> the view's month (defensive: no hub row throws here). */
export function costMonthOf(body) {
  const b = body && typeof body === 'object' ? body : {}
  const total = b.total && typeof b.total === 'object' ? b.total : {}
  return {
    month: str(b.month),
    from: str(b.from),
    to: str(b.to),
    status: b.status === 'so_far' || b.status === 'closed' ? b.status : 'ended',
    scope: b.scope === 'estate' ? 'estate' : 'workspace',
    secondCurrency: costCurrency(b.second_currency) || COST_SECOND_DEFAULT,
    days: int(b.days),
    daysEnded: int(b.days_ended),
    total: { usdMicros: int(total.usd_micros), eurMicros: int(total.eur_micros), secondMicros: intOrNull(total.second_micros) },
    parts: Array.isArray(b.parts) ? b.parts.map(costPartOf) : [],
    coverage: Array.isArray(b.coverage) ? b.coverage.map(costCoverageOf) : [],
    /* spec 140 3.10: every workspace's token burn, the estate answer's only */
    workspaces: b.scope === 'estate' && Array.isArray(b.workspaces) ? b.workspaces.map(costWorkspaceOf) : [],
  }
}

/** A rate, "0.9234" / "10.6" in the reader's locale (up to 4 decimals). */
export function costFxRate(rate, locale = 'en') {
  const n = Number(rate)
  if (rate === null || rate === undefined || !Number.isFinite(n) || n <= 0) return ''
  try {
    return new Intl.NumberFormat(locale, { maximumFractionDigits: 4 }).format(n)
  } catch {
    return String(Math.round(n * 1e4) / 1e4)
  }
}

/**
 * One second-currency cell: the amount, and the i18n key + params of its
 * title. A part with a rate: "rate" (one rate day) or "rate_span" (its cost
 * days took rates from `first` to `day`). No rate: an em dash and "none".
 * The total row (no rate of its own): the amount, or the dash and "none".
 * @param {{ secondMicros: number|null, fxRate?: number|null, fxRateDay?: string, fxRateFirstDay?: string }} p
 */
export function costSecondCell(p, currency = COST_SECOND_DEFAULT, locale = 'en') {
  const cur = costCurrency(currency) || COST_SECOND_DEFAULT
  if (!p || p.secondMicros === null || p.secondMicros === undefined) {
    return { text: '\u2014', none: true, key: 'none', params: { currency: cur } }
  }
  const text = costMoney(p.secondMicros, cur, locale)
  if (!p.fxRateDay) return { text, none: false, key: '', params: {} }
  const params = { currency: cur, rate: costFxRate(p.fxRate, locale), day: p.fxRateDay, first: p.fxRateFirstDay || p.fxRateDay }
  return { text, none: false, key: params.first !== params.day ? 'rate_span' : 'rate', params }
}

/** The picker's list from GET /v1/tenant/fx/currencies: codes, sorted, the default and `keep` always in. */
export function costCurrencyOptions(body, keep = '') {
  const b = body && typeof body === 'object' ? body : {}
  const def = costCurrency(b.default) || COST_SECOND_DEFAULT
  const out = new Set([def])
  for (const c of Array.isArray(b.currencies) ? b.currencies : []) if (costCurrency(c)) out.add(costCurrency(c))
  if (costCurrency(keep)) out.add(costCurrency(keep))
  return { default: def, currencies: [...out].sort() }
}

/** Is a source the GCP estate's (its reader names it gcp...). */
function costIsGcp(source) {
  return /^gcp/.test(String(source || ''))
}

/**
 * The sources with no money this month: every source a part or a coverage
 * row names whose parts sum to 0 USD (today's token and agent-hour rows are
 * counts only), plus GCP in the estate view while no GCP row exists (the
 * billing export is not live yet, spec 123 section 6). The page names each
 * one, so a missing figure never reads as a 0 cost.
 * @param {ReturnType<typeof costMonthOf>} m
 * @returns {string[]}
 */
export function costEmptySources(m) {
  const usd = new Map()
  for (const p of m.parts) usd.set(p.source, (usd.get(p.source) || 0) + p.usdMicros)
  for (const c of m.coverage) if (!usd.has(c.source)) usd.set(c.source, 0)
  const out = [...usd].filter(([, v]) => v <= 0).map(([s]) => s)
  if (m.scope === 'estate' && ![...usd.keys()].some(costIsGcp)) out.unshift('gcp')
  return out
}

/**
 * Per source, "n of N days complete": ok of the days that ended, with the
 * partial, missing and unrecorded days named.
 * @param {ReturnType<typeof costMonthOf>} m
 */
export function costCoverageRows(m) {
  return m.coverage.map((c) => ({ ...c, complete: c.days > 0 && c.ok >= c.days }))
}

/** The months the picker offers: now's UTC month first, then `back - 1` earlier ones. No future month. */
export function costMonthOptions(now = new Date(), back = COST_MONTHS_BACK) {
  const d = now instanceof Date && !Number.isNaN(now.getTime()) ? now : new Date()
  const out = []
  let y = d.getUTCFullYear()
  let mo = d.getUTCMonth() + 1
  for (let i = 0; i < back; i++) {
    out.push(`${y}-${String(mo).padStart(2, '0')}`)
    mo -= 1
    if (mo === 0) { mo = 12; y -= 1 }
  }
  return out
}

const fix = (n) => Math.round(n * 100) / 100

function arcPoint(cx, cy, r, frac) {
  const a = 2 * Math.PI * frac - Math.PI / 2
  return [fix(cx + r * Math.cos(a)), fix(cy + r * Math.sin(a))]
}

/** The SVG path of one slice [from, to) of a circle (fractions of a turn, 0 = 12 o'clock); a whole turn is two halves. */
export function costPieArc(from, to, r = 50, cx = 50, cy = 50) {
  if (to - from >= 0.9999) {
    return `M ${cx} ${cy - r} A ${r} ${r} 0 1 1 ${cx} ${cy + r} A ${r} ${r} 0 1 1 ${cx} ${cy - r} Z`
  }
  const [x0, y0] = arcPoint(cx, cy, r, from)
  const [x1, y1] = arcPoint(cx, cy, r, to)
  const large = to - from > 0.5 ? 1 : 0
  return `M ${cx} ${cy} L ${x0} ${y0} A ${r} ${r} 0 ${large} 1 ${x1} ${y1} Z`
}

/**
 * The pie: one slice per part with money and a share over `minPct` %, the
 * rest folded into one "other" slice (last), the parts largest first.
 * Shares are of the USD total from the micros (never the hub's rounded
 * pct), and the last slice closes the turn, so the slices sum to exactly
 * one. No money at all -> no slices (no pie).
 * @param {ReturnType<typeof costMonthOf>['parts']} parts
 */
export function costPieSlices(parts, minPct = COST_PIE_MIN_PCT) {
  const paid = (parts || []).filter((p) => p.usdMicros > 0)
  const total = paid.reduce((s, p) => s + p.usdMicros, 0)
  if (total <= 0) return []
  const big = []
  let other = 0
  let otherN = 0
  for (const p of paid) {
    if ((p.usdMicros * 100) / total > minPct) big.push(p)
    else { other += p.usdMicros; otherN += 1 }
  }
  big.sort((a, b) => b.usdMicros - a.usdMicros)
  const rows = big.map((p) => ({ key: costPartKey(p), other: false, part: p, usdMicros: p.usdMicros, n: 1 }))
  if (otherN > 0) rows.push({ key: 'other', other: true, part: null, usdMicros: other, n: otherN })
  let at = 0
  return rows.map((r, i) => {
    const frac = r.usdMicros / total
    const from = at
    const to = i === rows.length - 1 ? 1 : at + frac
    at = to
    return { ...r, frac, pct: Math.round(frac * 1000) / 10, from, to, d: costPieArc(from, to) }
  })
}

/** The slice colours, in order (fill attributes, never a style: CSP); readable on light and dark. */
export const COST_PIE_COLORS = Object.freeze(['#3b82f6', '#f59e0b', '#10b981', '#ef4444', '#8b5cf6', '#06b6d4', '#ec4899', '#84cc16', '#f97316', '#6366f1'])
export const COST_PIE_OTHER_COLOR = '#9ca3af'

/** A slice's colour: the palette in order, "other" grey. */
export function costSliceColor(slice, i) {
  return slice.other ? COST_PIE_OTHER_COLOR : COST_PIE_COLORS[i % COST_PIE_COLORS.length]
}

/* ---- the mock (e2e on the mock bundle; dev has no cost rows at all) ---- */

function mockWindow(month, now) {
  const [y, mo] = month.split('-').map(Number)
  const first = Date.UTC(y, mo - 1, 1)
  const next = Date.UTC(y, mo, 1)
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())
  const days = Math.round((next - first) / 86400000)
  const soFar = today < next
  const ended = soFar ? Math.max(0, Math.round((today - first) / 86400000)) : days
  const iso = (t) => new Date(t).toISOString().slice(0, 10)
  return { days, ended, soFar, from: iso(first), to: iso(next - 86400000) }
}

const toMicros = (n) => Math.round(n * 1e6)
const MOCK_EUR_PER_USD = 0.92
/** The mock's rates (units per USD), the currencies its picker lists (dev holds 28 real ones). */
export const MOCK_FX_RATES = Object.freeze({ EUR: MOCK_EUR_PER_USD, GBP: 0.79, SEK: 10.5, BGN: 1.8, JPY: 150 })

function mockPart(source, pov, kind, origin, usd, extra = {}) {
  return {
    estate: true,
    source,
    project_or_vendor: pov,
    kind,
    origin,
    units: extra.units || 0,
    usd_micros: toMicros(usd),
    eur_micros: toMicros(usd * MOCK_EUR_PER_USD),
    list_value_micros: extra.list ? toMicros(extra.list) : null,
    days: extra.days || 0,
  }
}

/* the mock's second currency (spec 123 5.4): each part at one rate dated the
   month's last ended day; 'norate' leaves the invoice part (and so the
   total) with no rate, as the hub answers a day before the first rate */
function mockSecond(parts, cur, w, scenario) {
  const rate = MOCK_FX_RATES[cur]
  const last = w.ended > 0 ? new Date(Date.UTC(+w.from.slice(0, 4), +w.from.slice(5, 7) - 1, w.ended)).toISOString().slice(0, 10) : w.from
  let total = 0
  for (const p of parts) {
    const none = !rate || (scenario === 'norate' && p.origin === 'invoice')
    p.second_micros = none ? null : Math.round(p.usd_micros * rate)
    p.fx_rate = none ? null : rate
    p.fx_rate_day = none ? null : last
    p.fx_rate_first_day = none ? null : (p.days > 1 ? w.from : last)
    total = total === null || p.second_micros === null ? null : total + p.second_micros
  }
  return total
}

/**
 * The mock month: a full estate month, ('empty') today's prd shape, counts
 * only and no GCP, or ('norate') the full month with a rate-less invoice.
 * `currency` is the reader's second currency (the hub reads it from the
 * session; the mock is handed it).
 */
export function mockTenantCostsBody(month = '', scenario = '', now = new Date(), currency = COST_SECOND_DEFAULT) {
  const m = MONTH_RE.test(month) ? month : costMonthOptions(now, 1)[0]
  const w = mockWindow(m, now)
  const n = w.ended
  const parts = scenario === 'empty'
    ? [
        mockPart('fleet_tokens', 'llm-vendor', 'tokens', 'transcript', 0, { units: 2.6e9, days: n }),
        mockPart('agent_hours', 'fleet', 'agent_seconds', 'agent_run', 0, { units: 9.1e5, days: n }),
      ]
    : [
        mockPart('gcp', 'project-prd', 'cloud_sql', 'estimate', 63.5, { days: n }),
        mockPart('gcp', 'project-all', 'compute', 'estimate', 55, { days: n }),
        mockPart('gcp', 'project-prd', 'cloud_run', 'estimate', 41.2, { days: n }),
        mockPart('gcp', 'project-dev', 'cloud_run', 'estimate', 8.1, { days: n }),
        mockPart('gcp', 'project-prd', 'network', 'estimate', 0.4, { days: n }),
        mockPart('gcp', 'project-dev', 'firebase_hosting', 'estimate', 0.2, { days: n }),
        mockPart('hand', 'llm-vendor', 'subscription', 'invoice', 200, { list: 1450, days: 1 }),
        mockPart('fleet_tokens', 'llm-vendor', 'tokens', 'transcript', 0, { units: 2.6e9, list: 1200, days: n }),
        mockPart('agent_hours', 'fleet', 'agent_seconds', 'agent_run', 0, { units: 9.1e5, days: n }),
      ]
  const usd = parts.reduce((s, p) => s + p.usd_micros, 0)
  const eur = parts.reduce((s, p) => s + p.eur_micros, 0)
  for (const p of parts) {
    p.hand = p.origin === 'hand' || p.origin === 'invoice'
    p.pct = usd > 0 ? Math.round((p.usd_micros * 1000) / usd) / 10 : null
  }
  const cur = costCurrency(currency) || COST_SECOND_DEFAULT
  const second = mockSecond(parts, cur, w, scenario)
  const cover = (source, ok, partial = 0, missing = 0) => ({ source, ok, partial, missing, unrecorded: Math.max(0, n - ok - partial - missing), days: n })
  const coverage = scenario === 'empty'
    ? [cover('agent_hours', n), cover('fleet_tokens', n)]
    : [cover('agent_hours', Math.max(0, n - 2), 0, Math.min(1, n)), cover('fleet_tokens', n), cover('gcp', Math.max(0, n - 1), Math.min(1, n))]
  return {
    month: m,
    from: w.from,
    to: w.to,
    status: w.soFar ? 'so_far' : 'ended',
    scope: 'estate',
    second_currency: cur,
    days: w.days,
    days_ended: n,
    total: { usd_micros: usd, eur_micros: eur, second_micros: second },
    parts,
    coverage,
    /* spec 140 3.10: the operator admin's every-workspace burn (the workspace ids are the mock's) */
    workspaces: [
      { workspace: 'ws-alpha', vendor: 'claude', tokens: 4.2e7, list_value_micros: toMicros(13.89), days: 1 },
      { workspace: 'ws-alpha', vendor: 'agy', tokens: 4.7e7, list_value_micros: 0, days: 1 },
      { workspace: 'ws-operator', vendor: 'claude', tokens: 2.1e9, list_value_micros: toMicros(950), days: n },
    ],
  }
}

function costsError(status, token, detail, permission) {
  const err = new Error(detail || token)
  err.status = status
  err.token = token
  err.detail = detail || ''
  if (permission) err.permission = permission
  return err
}

/**
 * The mock GET with the hub's refusals: a mock member whose permission list
 * lacks costs.read gets the 403 naming it; a future month is 400. `me` is
 * the opt-in mock { permissions } (act-as-mock.mjs mockMeGet); `currency`
 * the reader's second currency (the session's second_currency).
 */
export function mockTenantCosts(month = '', { me = null, now = new Date(), scenario, currency = '' } = {}) {
  if (me && Array.isArray(me.permissions) && !me.permissions.includes(COSTS_READ)) {
    throw costsError(403, 'forbidden', 'your role in this tenant does not grant ' + COSTS_READ, COSTS_READ)
  }
  if (month && !MONTH_RE.test(month)) throw costsError(400, 'bad_query', 'month must be YYYY-MM')
  if (month && month > costMonthOptions(now, 1)[0]) throw costsError(400, 'bad_query', 'month ' + month + ' has not started')
  const sc = scenario === undefined ? String(storageGet(COSTS_MOCK_KEY, '') || '') : scenario
  return mockTenantCostsBody(month, sc, now, currency || COST_SECOND_DEFAULT)
}

/** The mock GET /v1/tenant/fx/currencies. */
export function mockFxCurrencies() {
  return { default: COST_SECOND_DEFAULT, currencies: Object.keys(MOCK_FX_RATES).sort() }
}
