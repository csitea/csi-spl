/**
 * Spec 143 expenses-cost-entries.md (SPL-4382, on SPL-4383's hub routes; owner
 * HUM-10, t1 4f48f878, msg b0ccc0aa: "different types for the INSERTION"): the
 * Cloud infra and HR tabs of Expenses enter one cost of one month, over
 *   GET /v1/operator/cost-entries?type=cloud|hr, POST, DELETE .../{id}
 * (hub internal/hub/cost_entries.go, store/cost_entries.go).
 *
 * The form's checks mirror store.CheckCostEntry, so a bad entry is named before
 * it is sent; the hub still has the last word and its text is shown as it comes.
 * Amounts are net of VAT (owner poll 68d7f768, answer 4 NET).
 *
 * Lazy like monitoring-paid.mjs: only the card and the lazy spool client import
 * it. Node tests import it.
 */

import { mockError, mockGate, mockStore, PAID_MOCK_FX } from './monitoring-paid.mjs'
import { sortRowsBy, uniqSorted } from './monitoring-lanes.mjs'

/** The types the tabs enter (store.CostEntryTypes). */
export const COST_ENTRY_TYPES = Object.freeze(['cloud', 'hr'])
/** e2e opt-in (mock only): the mock's entries, a JSON array kept between page loads. */
export const COST_ENTRIES_MOCK_KEY = 'spool.mock.cost_entries'
/** e2e opt-in (mock only): when set, the next add is refused (400 bad_cost_entry) with this text, as the hub would. */
export const COST_ENTRIES_MOCK_REFUSE_KEY = 'spool.mock.cost_entries_refuse'

const MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])$/
const CUR_RE = /^[A-Z]{3}$/
const AMOUNT_MAX = 1e10
const LABEL_MAX = 100
const NOTE_MAX = 2000
const str = (v) => (typeof v === 'string' ? v : '')
/* the hub counts bytes (Go len), so a Cyrillic label reaches its limit sooner */
const bytes = (s) => new TextEncoder().encode(s).length
const micro = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null)

/** GET .../cost-entries ({entries: [...]}) as rows, the newest month first; an entry with no id is dropped. */
export function costEntriesOf(body) {
  const entries = body && typeof body === 'object' && Array.isArray(body.entries) ? body.entries : []
  return entries.filter((e) => e && typeof e === 'object' && str(e.id)).map((e) => ({
    id: str(e.id),
    type: str(e.type),
    label: str(e.label),
    amount: Number.isFinite(e.amount) ? e.amount : null,
    currency: str(e.currency),
    period: str(e.period),
    note: str(e.note),
    /* SPL-5198: the amount in USD and EUR at the month's rates (hub
       store.PriceCostEntries), micros; null = no rate made it, never 0 */
    usdMicros: micro(e.usd_micros),
    eurMicros: micro(e.eur_micros),
  })).sort((a, b) => b.period.localeCompare(a.period))
}

/** An empty form: this UTC month, USD. */
export function emptyCostEntryForm(now = new Date()) {
  return { label: '', amount: '', currency: 'USD', period: now.toISOString().slice(0, 7), note: '' }
}

/**
 * The first thing the form may not send, as an i18n key under expenses.entries
 * ('' = fine): store.CheckCostEntry's rules, plus a currency the hub holds a
 * rate for (`currencies`), since an unrated amount reads as no USD in Costs.
 */
export function checkCostEntryForm(f, currencies = ['USD']) {
  const label = str(f.label).trim()
  const amount = Number(f.amount)
  if (!label || bytes(label) > LABEL_MAX) return 'err_label'
  if (f.amount === '' || !Number.isFinite(amount) || amount <= 0 || amount >= AMOUNT_MAX) return 'err_amount'
  if (!CUR_RE.test(str(f.currency)) || !currencies.includes(f.currency)) return 'err_currency'
  if (!MONTH_RE.test(str(f.period))) return 'err_period'
  if (bytes(str(f.note)) > NOTE_MAX) return 'err_note'
  return ''
}

/** The POST body of a checked form, for one tab's type. */
export function costEntryBody(type, f) {
  return { type, label: str(f.label).trim(), amount: Number(f.amount), currency: f.currency, period: f.period, note: str(f.note) }
}

function mockRead(store) {
  try {
    const list = JSON.parse(store.getItem(COST_ENTRIES_MOCK_KEY) || '[]')
    return Array.isArray(list) ? list : []
  } catch {
    return []
  }
}

function mockWrite(store, list) {
  try { store.setItem(COST_ENTRIES_MOCK_KEY, JSON.stringify(list)) } catch { /* the mock forgets */ }
}

/* the mock's USD and EUR of an entry at its one rate per currency (units per
   USD: PAID_MOCK_FX, held equal to tenant-costs MOCK_FX_RATES; this file never
   imports tenant-costs.mjs, the chunk rule); a currency it holds no rate of is
   null, as the hub */
function mockPriced(e, rates) {
  const rate = e.currency === 'USD' ? 1 : rates[e.currency]
  const own = Math.round(Number(e.amount) * 1e6)
  const usd = rate ? Math.round(own / rate) : null
  const eur = e.currency === 'EUR' ? own : usd === null || !rates.EUR ? null : Math.round(usd * rates.EUR)
  return { ...e, usd_micros: usd, eur_micros: eur }
}

/** The mock's GET: one type's entries, priced; 403 to anyone but an operator admin. */
export function mockCostEntryList(type, store = mockStore(), rates = PAID_MOCK_FX) {
  mockGate(store)
  return { entries: mockRead(store).filter((e) => e.type === type).map((e) => mockPriced(e, rates)) }
}

/** The mock's POST: stores the body, or refuses once when COST_ENTRIES_MOCK_REFUSE_KEY is set. */
export function mockCostEntryCreate(body, store = mockStore(), now = new Date()) {
  mockGate(store)
  let refuse = null
  try { refuse = store.getItem(COST_ENTRIES_MOCK_REFUSE_KEY) } catch { /* none */ }
  if (refuse) {
    try { store.removeItem(COST_ENTRIES_MOCK_REFUSE_KEY) } catch { /* kept */ }
    throw mockError(400, 'bad_cost_entry', refuse)
  }
  const list = mockRead(store)
  const e = { ...body, id: 'mock-cost-' + now.getTime().toString(36) + '-' + list.length, created_by: 'HUM-1', created_at: now.toISOString() }
  mockWrite(store, [...list, e])
  return e
}

/** The mock's DELETE: 404 on an unknown id. */
export function mockCostEntryDelete(id, store = mockStore()) {
  mockGate(store)
  const list = mockRead(store)
  if (!list.some((e) => e.id === id)) throw mockError(404, 'not_found', 'no cost entry ' + id)
  mockWrite(store, list.filter((e) => e.id !== id))
  return null
}

/*
 * SPL-5198 (owner HUM-10, t1 965283be msg 382450e2: "listing should have
 * sorting and filtering simir to the issues listing , it must also have the
 * pricess in dollars and euros"): the list's sort and filter row, the Lanes
 * sheet's (SPL-3887) on the same pieces: a header click cycles the sort
 * (sheet-sort.mjs cycleSort, components/SheetSortButton.vue), sortRowsBy
 * orders, the row under the names filters by text, month and currency.
 */

/** The sortable columns, in the table's order. */
export const COST_ENTRY_COLUMNS = Object.freeze(['label', 'usd', 'eur', 'period'])
/** No filter: every row. */
export const COST_ENTRY_NO_FILTER = Object.freeze({ text: '', period: '', currency: '' })

/* a column's value to sort on; null (no rate) sorts last either way */
function costEntryValue(e, col) {
  if (col === 'usd') return e.usdMicros
  if (col === 'eur') return e.eurMicros
  return col === 'period' ? e.period || null : e.label || null
}

/** The rows in a sheet sort ({ col: '', dir: '' } = the newest month first, as read). */
export function sortCostEntries(rows, sort) {
  return sortRowsBy(rows, sort, COST_ENTRY_COLUMNS, costEntryValue)
}

/**
 * The rows the filter row keeps: every word of `text` in the label or the
 * note, and the month and the entered currency each '' (any) or equal.
 * @param {{ text?: string, period?: string, currency?: string }} f
 */
export function filterCostEntries(rows, f) {
  const words = str(f.text).toLowerCase().split(/\s+/).filter(Boolean)
  return rows.filter((e) => (!f.period || e.period === f.period)
    && (!f.currency || e.currency === f.currency)
    && (words.length === 0 || words.every((w) => (e.label + ' ' + e.note).toLowerCase().includes(w))))
}

/** True when any filter is set. */
export function costEntriesFiltered(f) {
  return Boolean(str(f.text).trim() || f.period || f.currency)
}

/** The month and currency selects' choices: the values the rows hold, months newest first. */
export function costEntryFilterChoices(rows) {
  return { period: uniqSorted(rows.map((e) => e.period)).reverse(), currency: uniqSorted(rows.map((e) => e.currency)) }
}

/**
 * One amount cell, USD or EUR: its micros (null = no rate of the month) and
 * whether a rate made it (the entry was entered in another currency).
 * @param {{ currency: string, usdMicros: number|null, eurMicros: number|null }} e
 * @param {'USD' | 'EUR'} cur
 */
export function costEntryCell(e, cur) {
  const micros = cur === 'USD' ? e.usdMicros : e.eurMicros
  return { amount: micros === null ? null : micros / 1e6, converted: e.currency !== cur, none: micros === null }
}

/** The shown rows' sums in USD and EUR, units; null when a row has no rate (never a partial sum). */
export function costEntryTotals(rows) {
  const sum = (k) => (rows.some((e) => e[k] === null) ? null : rows.reduce((n, e) => n + e[k], 0) / 1e6)
  return { usd: sum('usdMicros'), eur: sum('eurMicros') }
}
