// csi-spl-wui/src/utils/costs-labels.mjs
//
// SPL-5312 (spec 143 costs-redesign.md 3.9; owner HUM-10, t1 41a74806,
// 2026-11-11): Reporting -> Costs is four labels, Total, Persons, Cloud and
// Tokens. Each shows, straight after its name, a pie of its items (value and
// share visible), then a sortable table of its items per month of the
// period (one of the last 12 months, or the year to date).
//
// The one place a workspace's numbers are made (owner poll 0c5e94b4, answer
// C "Both A and B"): costsLabelRows reads the month answers of
// GET /v1/tenant/costs, already scoped by the hub (the operator admin: the
// estate; any other reader: its workspace), and sorts each part into its
// label. The hand allocation of a shared cost to workspaces (answer B, spec
// 143 costs-allocation.md) feeds the same function: an allocated part names
// its own label through `allocatedSource`.
//
// Pure parts, loaded by the label pages only; the money is formatted by
// utils/tenant-costs.mjs.

import { CLOUD_SOURCE, ENTRY_SOURCE, cloudProjectOf, cloudServiceDays, cloudTotal, sectionAmount } from './costs-sections.mjs'
import { COST_PIE_COLORS, costPieArc } from './tenant-costs.mjs'

/** The labels in their order (the page bar's, utils/reporting-costs.mjs). */
export const COSTS_LABEL_IDS = Object.freeze(['total', 'persons', 'cloud', 'tokens'])
/** Total's items: the three labels, then what fits none (e.g. agent hours, a count). */
const TOTAL_ITEMS = Object.freeze(['persons', 'cloud', 'tokens', 'other'])
const TOKEN_SOURCES = Object.freeze(['fleet_tokens', 'ai_paid', 'ai_share'])
/* a paid AI item entered before the ai_paid source (the mock's invoice) */
const TOKEN_KINDS = Object.freeze(['tokens', 'subscription', 'share'])

/**
 * The label a cost part counts under: an hr entry is Persons; GCP and a
 * hand-entered cloud cost are Cloud; the token burn, the paid AI items and a
 * workspace's share of them are Tokens; anything else is Total's "other".
 * @param {{ source: string, kind: string, allocatedSource?: string }} p
 */
export function costLabelOf(p) {
  const src = String((p && (p.allocatedSource || p.source)) || '').split('.')[0]
  if (src === ENTRY_SOURCE) return p.kind === 'hr' ? 'persons' : 'cloud'
  if (src === CLOUD_SOURCE) return 'cloud'
  if (TOKEN_SOURCES.includes(src) || TOKEN_KINDS.includes(p.kind)) return 'tokens'
  return 'other'
}

/** A month answer's parts, its hr entries (the estate's `human` list) included. */
function monthParts(m) {
  return [...(m && Array.isArray(m.parts) ? m.parts : []), ...(m && Array.isArray(m.human) ? m.human : [])]
}

/** A part's item under `label` ({ key, name, ... }), or null when it is not the label's. */
function itemOf(label, p, project) {
  const of = costLabelOf(p)
  if (label === 'total') return { key: of, name: of }
  if (of !== label) return null
  if (label === 'cloud') return cloudItemOf(p, project)
  if (label === 'tokens') return { key: [p.source, p.projectOrVendor, p.kind].join('|'), name: p.projectOrVendor, source: p.source, kind: p.kind }
  return personsItemOf(p)
}

/**
 * Persons: a row per hr group (SPL-5433 step b, spec 123 16.3), never a
 * person; a line without a component (before rdb 0280, or the
 * organisation's free label) keeps its own label as its row.
 */
function personsItemOf(p) {
  if (p.group) return { key: 'hr-group:' + p.group, name: p.group, group: p.group }
  return { key: 'hr:' + p.projectOrVendor, name: p.projectOrVendor }
}

/** Cloud: a GCP project (its box apart) or a hand-entered cost; inside a project, its services. */
function cloudItemOf(p, project) {
  const entry = p.source === ENTRY_SOURCE
  if (project) return entry || p.projectOrVendor !== project ? null : { key: p.kind, name: p.kind, drill: 'kind' }
  if (entry) return { key: 'entry:' + p.projectOrVendor, name: p.projectOrVendor, entry: true }
  return { key: p.projectOrVendor, name: cloudProjectOf(p.projectOrVendor).project, box: cloudProjectOf(p.projectOrVendor).box, drill: 'project' }
}

/**
 * One cell: the parts of an item in one month, in `currency`. `v` null =
 * no amount (every part unpriced in USD, or no rate to the second currency;
 * never a guess); `left` = the parts the amount leaves out; `empty` = the
 * item had no part that month.
 */
function cellOf(parts, currency) {
  if (!parts.length) return { v: 0, left: 0, empty: true }
  const m = cloudTotal(parts)
  const left = (currency === 'USD' ? m.unpricedRows : m.secondLeftRows) || 0
  if (left === parts.length) return { v: null, left, empty: false }
  const v = sectionAmount(m, currency)
  return { v: v === undefined ? null : v, left, empty: false }
}

/**
 * The sum of cells (a row's total, a column's total): null when no cell has an
 * amount. `none` counts the summed cells with no amount, through nested sums
 * (a footer total sums row totals), so a total that leaves one out is marked
 * (c-974 review N1, SPL-5312).
 */
export function costsCellSum(cells) {
  const has = cells.filter((c) => !c.empty)
  const vals = has.filter((c) => c.v !== null)
  const left = has.reduce((s, c) => s + c.left, 0)
  const none = has.reduce((s, c) => s + (c.v === null ? (c.none || 1) : (c.none || 0)), 0)
  if (has.length && !vals.length) return { v: null, left, empty: false, none }
  return { v: vals.reduce((s, c) => s + c.v, 0), left, empty: !has.length, none }
}

function finishRow(r, currency) {
  const cells = r.parts.map((ps) => cellOf(ps, currency))
  const { parts, ...rest } = r
  return { ...rest, cells, total: costsCellSum(cells), hand: parts.flat().some((p) => p.hand) }
}

/**
 * A label's rows over the period's months: one row per item, its cell per
 * month and its total, in `currency`; the share is of the label's positive
 * totals. The most expensive first. `project` (Cloud): that project's
 * services instead of the projects.
 * @param {string} label one of COSTS_LABEL_IDS
 * @param {Array<any>} months the costMonthOf answers, oldest first
 * @param {{ currency?: string, project?: string }} [opts]
 */
export function costsLabelRows(label, months, { currency = 'USD', project = '' } = {}) {
  const list = Array.isArray(months) ? months : []
  const byKey = new Map()
  list.forEach((m, i) => {
    for (const p of monthParts(m)) {
      const it = itemOf(label, p, project)
      if (!it) continue
      if (!byKey.has(it.key)) byKey.set(it.key, { ...it, parts: list.map(() => []), units: 0, listMicros: 0 })
      const row = byKey.get(it.key)
      row.parts[i].push(p)
      row.units += Number(p.units) || 0
      row.listMicros += p.listValueMicros || 0
      if (p.entryCurrency) addEntry(row, p)
    }
  })
  if (label === 'total') for (const id of TOTAL_ITEMS.slice(0, 3)) if (!byKey.has(id)) byKey.set(id, { key: id, name: id, parts: list.map(() => []), units: 0, listMicros: 0 })
  return withShares([...byKey.values()].map((r) => finishRow(r, currency)), label === 'total')
}

/* a hand-entered cost's own amount, summed while its currency is one (else none) */
function addEntry(row, p) {
  if (row.entryCurrency === undefined) Object.assign(row, { entryCurrency: p.entryCurrency, entryMicros: 0 })
  if (row.entryCurrency !== p.entryCurrency) row.entryCurrency = ''
  row.entryMicros += p.entryMicros || 0
}

/** Rows get their share of the positive totals, the most expensive first (Total keeps its label order). */
function withShares(rows, total) {
  const sum = rows.reduce((s, r) => s + (r.total.v > 0 ? r.total.v : 0), 0)
  const out = rows.map((r) => ({ ...r, pct: sum > 0 && r.total.v !== null && r.total.v >= 0 ? Math.round((r.total.v * 1000) / sum) / 10 : null }))
  const order = (r) => TOTAL_ITEMS.indexOf(r.key)
  if (total) return out.filter((r) => r.key !== 'other' || !r.total.empty).sort((a, b) => order(a) - order(b))
  return out.sort((a, b) => (b.total.v ?? -1) - (a.total.v ?? -1) || String(a.key).localeCompare(String(b.key)))
}

/**
 * Cloud's day level (one service of one project, a single month): the
 * days of GET /v1/tenant/costs/cloud, oldest first, as rows of one cell.
 * @param {{ days: Array<any> } | null} days the cloudDaysOf view
 * @param {string} kind
 * @param {string} currency
 */
export function costsDayRows(days, kind, currency) {
  const rows = cloudServiceDays(days, kind).map((d) => {
    const v = sectionAmount(d, currency)
    const cell = { v: v === undefined ? null : v, left: 0, empty: false }
    return { key: d.day, name: d.day, cells: [cell], total: cell }
  })
  const sum = rows.reduce((s, r) => s + (r.total.v > 0 ? r.total.v : 0), 0)
  return rows.map((r) => ({ ...r, pct: sum > 0 && r.total.v !== null ? Math.round((r.total.v * 1000) / sum) / 10 : null }))
}

/** The footer: each month's total and the period's. @param {Array<any>} rows */
export function costsColumnTotals(rows, months) {
  const n = Array.isArray(months) ? months.length : 0
  const cols = []
  for (let i = 0; i < n; i++) cols.push(costsCellSum(rows.map((r) => r.cells[i]).filter(Boolean)))
  return { cells: cols, total: costsCellSum(rows.map((r) => r.total)) }
}

/**
 * The pie of a label: one slice per row with a positive total, in the
 * rows' order; the last slice closes the turn. No money -> no slices.
 * @param {Array<any>} rows costsLabelRows
 */
export function costsLabelSlices(rows) {
  const paid = (rows || []).filter((r) => r.total.v > 0)
  const sum = paid.reduce((s, r) => s + r.total.v, 0)
  if (sum <= 0) return []
  let at = 0
  return paid.map((r, i) => {
    const frac = r.total.v / sum
    const from = at
    const to = i === paid.length - 1 ? 1 : at + frac
    at = to
    return { key: r.key, row: r, v: r.total.v, pct: Math.round(frac * 1000) / 10, d: costPieArc(from, to), color: COST_PIE_COLORS[i % COST_PIE_COLORS.length] }
  })
}

/** A sort column: 'name' (the shown name, else the item's), 'total', 'pct' or a month index. */
function sortValue(r, col) {
  if (col === 'name') return r.display ?? r.name
  if (col === 'pct') return r.pct
  const c = col === 'total' ? r.total : r.cells[Number(col)]
  return !c || c.v === null ? null : c.v
}

/**
 * Rows in a header click's order: `dir` 'ascending' or 'descending'; a cell
 * with no amount (a dash) last both ways; equal keys keep their order.
 * @param {Array<any>} rows
 * @param {string | number} col
 * @param {'ascending' | 'descending'} dir
 * @param {string} [locale]
 */
export function costsSortRows(rows, col, dir, locale = 'en') {
  const sign = dir === 'descending' ? -1 : 1
  return (rows || []).map((r, i) => ({ r, i, v: sortValue(r, col) })).sort((a, b) => {
    if (a.v === null || b.v === null) return (a.v === null) - (b.v === null) || a.i - b.i
    const d = typeof a.v === 'string' ? a.v.localeCompare(String(b.v), locale, { numeric: true, sensitivity: 'base' }) : a.v - b.v
    return d * sign || a.i - b.i
  }).map((x) => x.r)
}

/** The next sort after a click on `col`: a new column sorts its natural way first (names A-Z, money highest first), the same column flips. */
export function costsNextSort(sort, col) {
  if (sort && String(sort.col) === String(col)) return { col, dir: sort.dir === 'ascending' ? 'descending' : 'ascending' }
  return { col, dir: col === 'name' ? 'ascending' : 'descending' }
}

/**
 * The estate's token burn per workspace and vendor over the period (spec
 * 140 3.10, the operator admin's only): summed across the months.
 * @param {Array<any>} months the costMonthOf answers
 */
export function costsWorkspaceBurn(months) {
  const m = new Map()
  for (const mo of Array.isArray(months) ? months : []) {
    for (const w of mo.workspaces || []) {
      const k = w.workspace + '|' + w.vendor
      if (!m.has(k)) m.set(k, { key: k, workspace: w.workspace, vendor: w.vendor, tokens: 0, listValueMicros: 0 })
      const row = m.get(k)
      row.tokens += w.tokens
      row.listValueMicros += w.listValueMicros
    }
  }
  return [...m.values()]
}
