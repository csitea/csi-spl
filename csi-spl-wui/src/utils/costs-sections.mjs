// csi-spl-wui/src/utils/costs-sections.mjs
//
// SPL-4187 (spec 123 5.5; owner HUM-10, t1 e2c0e6b4, msgs 81217a3f,
// 156c8939, 8c7f4962): Reporting -> Costs gets three sections of their own,
// Cloud, AI tokens and Human. Cloud: level 1 one row per GCP project of the
// month read's gcp parts, level 2 a project's services (the line kind),
// level 3 a service per day from GET /v1/tenant/costs/cloud; level 1 also
// lists the month's hand-entered cloud costs (SPL-4824). AI tokens: the
// month read's token parts. Human: the month's hand-entered hr costs (the
// month read's human list, SPL-4840, outside the Spend total), else not
// tracked yet (spec 107 T071..T077).
// Pure parts, loaded by those pages only; the money is formatted by
// utils/tenant-costs.mjs.

/** The source the GCP reader writes (spec 123 4.2). */
export const CLOUD_SOURCE = 'gcp'
/** The source of the hand-entered costs (SPL-4824, rdb 0245 cost_entries). */
export const ENTRY_SOURCE = 'cost_entry'
/** The month read's AI token sources (spec 140 3.10, spec 143 3.3.1). */
const TOKEN_SOURCES = Object.freeze(['fleet_tokens', 'ai_paid', 'ai_share'])
/** The spec 107 rows that build the human costs (section 21). */
export const HUMAN_ROWS = 'T071..T077'

const MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])$/
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/
const int = (v) => (Number.isFinite(Number(v)) ? Math.trunc(Number(v)) : 0)
const intOrNull = (v) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Math.trunc(Number(v)))
const str = (v) => (typeof v === 'string' ? v : '')

/** "<project>/box=<label>" -> { project, box: label }; no label -> box '' (the reader's pov, spec 123 4.2). */
export function cloudProjectOf(pov) {
  const s = str(pov)
  const i = s.indexOf('/box=')
  return i < 0 ? { project: s, box: '' } : { project: s.slice(0, i), box: s.slice(i + 5) }
}

/** A row's amount in the header's currency: USD, else the second currency (null = no rate, never a guess; an unpriced entry has no USD). */
export function sectionAmount(r, currency) {
  if (!r) return null
  if (currency === 'USD') return r.unpriced ? null : r.usdMicros
  return r.secondMicros
}

/* unpricedRows: summed rows with no USD; secondLeftRows: unpriced rows with no
   second-currency amount either. A total leaves both out and says so; only a
   priced row with no rate blanks the second total (SPL-4824 R7 W1). */
const zero = () => ({ usdMicros: 0, eurMicros: 0, secondMicros: 0, unpricedRows: 0, secondLeftRows: 0 })
function add(acc, r) {
  const noSecond = r.secondMicros === null || r.secondMicros === undefined
  acc.usdMicros += r.usdMicros
  acc.unpricedRows = (acc.unpricedRows || 0) + (r.unpriced ? 1 : 0)
  acc.secondLeftRows = (acc.secondLeftRows || 0) + (r.unpriced && noSecond ? 1 : 0)
  acc.eurMicros += r.eurMicros
  if (r.unpriced && noSecond) return acc
  acc.secondMicros = acc.secondMicros === null || noSecond ? null : acc.secondMicros + r.secondMicros
  return acc
}
const byUsd = (a, b) => b.usdMicros - a.usdMicros || String(a.key).localeCompare(String(b.key))

/** The month's cloud parts (the estate's gcp lines). @param {Array<any>} parts the costMonthOf parts */
function cloudParts(parts) {
  return (Array.isArray(parts) ? parts : []).filter((p) => p && p.estate && p.source === CLOUD_SOURCE)
}

/** Level 1: one row per project (pov), the most expensive first, with its services counted. */
export function cloudProjects(parts) {
  const m = new Map()
  for (const p of cloudParts(parts)) {
    if (!m.has(p.projectOrVendor)) m.set(p.projectOrVendor, { key: p.projectOrVendor, pov: p.projectOrVendor, ...cloudProjectOf(p.projectOrVendor), ...zero(), kinds: new Set() })
    const row = add(m.get(p.projectOrVendor), p)
    row.kinds.add(p.kind)
  }
  return [...m.values()].map(({ kinds, ...r }) => ({ ...r, services: kinds.size })).sort(byUsd)
}

/**
 * Level 1, beside the projects (SPL-4824): the month's hand-entered cloud
 * costs, one row per entry, never drilled; the most expensive first.
 * @param {Array<any>} parts the costMonthOf parts
 */
export function cloudEntries(parts) {
  return entryRows(parts, 'cloud', 'entry:')
}

/**
 * Human (SPL-4840, owner csitea f7bba506 answer A "In Human; left out of
 * Spend"): the month's hand-entered hr costs, one row per entry, the most
 * expensive first.
 * @param {Array<any>} human the costMonthOf human list
 */
export function humanEntries(human) {
  return entryRows(human, 'hr', 'hr:')
}

/** The entries of `kind` among parts, one row each keyed `<prefix><label>:<i>`, the most expensive first. */
function entryRows(parts, kind, prefix) {
  return (Array.isArray(parts) ? parts : [])
    .filter((p) => p && p.estate && p.source === ENTRY_SOURCE && p.kind === kind)
    .map((p, i) => ({
      key: prefix + p.projectOrVendor + ':' + i, label: p.projectOrVendor, usdMicros: p.usdMicros, eurMicros: p.eurMicros,
      secondMicros: p.secondMicros, entryMicros: p.entryMicros, entryCurrency: p.entryCurrency, unpriced: p.unpriced === true,
    }))
    .sort(byUsd)
}

/** Level 2: one project's services (kind), the most expensive first. */
export function cloudServices(parts, pov) {
  const m = new Map()
  for (const p of cloudParts(parts)) {
    if (p.projectOrVendor !== pov) continue
    if (!m.has(p.kind)) m.set(p.kind, { key: p.kind, kind: p.kind, ...zero(), days: 0 })
    const row = add(m.get(p.kind), p)
    row.days = Math.max(row.days, p.days)
  }
  return [...m.values()].sort(byUsd)
}

/** The sum of rows (a level's total row). */
export function cloudTotal(rows) {
  return (Array.isArray(rows) ? rows : []).reduce(add, zero())
}

/** The query of GET /v1/tenant/costs/cloud. */
export function cloudDaysQuery(month, project) {
  const q = new URLSearchParams()
  if (MONTH_RE.test(String(month))) q.set('month', month)
  q.set('project', String(project || ''))
  return '?' + q.toString()
}

/** The hub's days body -> the view (defensive: no hub row throws here). */
export function cloudDaysOf(body) {
  const b = body && typeof body === 'object' ? body : {}
  const days = (Array.isArray(b.days) ? b.days : []).filter((d) => d && DAY_RE.test(str(d.day))).map((d) => ({
    day: d.day, kind: str(d.kind), usdMicros: int(d.usd_micros), eurMicros: int(d.eur_micros), secondMicros: intOrNull(d.second_micros),
  }))
  return { month: str(b.month), project: str(b.project), days }
}

/** Level 3: one service's days, oldest first. */
export function cloudServiceDays(view, kind) {
  return (view && Array.isArray(view.days) ? view.days : []).filter((d) => d.kind === kind).sort((a, b) => a.day.localeCompare(b.day))
}

/** The AI tokens section's parts: the month read's token sources (a box suffix too, `fleet_tokens.<box>`), in its order. */
export function tokenParts(parts) {
  return (Array.isArray(parts) ? parts : []).filter((p) => p && TOKEN_SOURCES.some((s) => p.source === s || p.source.startsWith(s + '.')))
}

/**
 * The mock GET /v1/tenant/costs/cloud: the mock month's gcp parts of
 * `project`, each spread evenly over the month's ended days (the hub sums
 * real lines per day). A non-operator reads the hub's 403.
 * @param {Record<string, any>} monthBody the mock month (mockTenantCostsBody)
 * @param {string} project
 * @param {{ operator?: boolean }} [who]
 */
export function mockCloudDays(monthBody, project, who = {}) {
  if (who.operator !== true) {
    const err = new Error('the cloud costs are the estate\'s: the operator workspace\'s admin only')
    Object.assign(err, { status: 403, token: 'forbidden' })
    throw err
  }
  const b = monthBody || {}
  const n = Math.max(1, int(b.days_ended))
  const days = []
  for (const p of Array.isArray(b.parts) ? b.parts : []) {
    if (p.source !== CLOUD_SOURCE || p.project_or_vendor !== project) continue
    for (let d = 1; d <= n; d++) {
      const share = (v) => (v === null || v === undefined ? null : Math.floor(v / n) + (d === n ? v % n : 0))
      days.push({ day: `${b.month}-${String(d).padStart(2, '0')}`, kind: p.kind, usd_micros: share(p.usd_micros), eur_micros: share(p.eur_micros), second_micros: share(p.second_micros) })
    }
  }
  return { month: b.month, project, second_currency: b.second_currency, days }
}
