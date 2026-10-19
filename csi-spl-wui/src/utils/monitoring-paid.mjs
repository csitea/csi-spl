/**
 * Spec 140 3.8 (SPL-2567, part 2 of SPL-2342; owner HUM-10, t1 e8ae0aad msg
 * 9f549412): the Tokens page's Paid card. The operator enters each paid
 * item (a subscription or a top-up) and reads the effective price per token
 * per vendor beside the list-price one, over
 *   GET/POST /v1/operator/fleet-tokens/paid, PATCH/DELETE .../paid/{id}
 *   GET /v1/operator/fleet-tokens/effective
 * (hub internal/hub/fleet_token_paid.go, store/fleet_token_paid.go).
 *
 * The form's checks mirror store.CheckFleetPaidItem, so a bad item is named
 * before it is sent; the hub still has the last word and its error text is
 * shown as it comes. Honest figures: a null price stays null (a dash with
 * its status), never a 0.
 *
 * Lazy like monitoring-tokens.mjs: only the Paid card and the lazy spool
 * client import it. Node tests import it.
 */

import { TOKENS_MOCK_OPERATOR_KEY, TOKENS_VENDORS } from './monitoring-tokens.mjs'

/** The item kinds (store.FleetPaidKinds). */
export const PAID_KINDS = Object.freeze(['subscription', 'topup'])
/** The effective read's vendor statuses (store.FleetPaidVendor). */
const PAID_STATUSES = Object.freeze(['effective', 'list_only', 'not_metered', 'no_fx_rate'])
/** e2e opt-in (mock only): the mock's paid items, a JSON array kept between page loads. */
export const PAID_MOCK_KEY = 'spool.mock.fleet_paid'
/** e2e opt-in (mock only): when set, the next add or edit is refused (400 bad_paid_item) with this text, as the hub would. */
export const PAID_MOCK_REFUSE_KEY = 'spool.mock.fleet_paid_refuse'
/** The mock's rates (units per USD): tenant-costs.mjs MOCK_FX_RATES, the codes mockFxCurrencies offers (a unit test holds them equal). */
export const PAID_MOCK_FX = Object.freeze({ EUR: 0.92, GBP: 0.79, SEK: 10.5, BGN: 1.8, JPY: 150 })
/** The mock's burn per vendor per day: [tokens, cache reads, list cost USD]; agy logs none. */
const MOCK_DAY = Object.freeze({ claude: [15800000, 8800000, 39.4], mistral: [2650000, 0, 2.75], grok: [900000, 0, 0], agy: [0, 0, 0], qwen: [0, 0, 0] })

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/
const CUR_RE = /^[A-Z]{3}$/
const DAY_MS = 86400000
const str = (v) => (typeof v === 'string' ? v : '')
const num = (v) => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v)) ? null : Number(v))

/** A UTC day YYYY-MM-DD as ms, else NaN (2026-02-30 is not a day). */
export function dayMs(d) {
  if (!DAY_RE.test(str(d))) return NaN
  const t = Date.parse(d + 'T00:00:00Z')
  return Number.isFinite(t) && new Date(t).toISOString().slice(0, 10) === d ? t : NaN
}

/** One paid item as the card's row. */
function itemOf(it) {
  return {
    id: str(it.id),
    vendor: str(it.vendor),
    kind: str(it.kind),
    planLabel: str(it.plan_label),
    quantity: Number.isInteger(it.quantity) ? it.quantity : 1,
    amount: num(it.amount),
    currency: str(it.currency),
    periodStart: str(it.period_start),
    periodEnd: str(it.period_end),
    note: str(it.note),
  }
}

/** GET .../paid ({items: [...]}) as rows; an item with no id is dropped. */
export function paidItemsOf(body) {
  const items = body && typeof body === 'object' && Array.isArray(body.items) ? body.items : []
  return items.filter((it) => it && typeof it === 'object' && str(it.id)).map(itemOf)
}

/** GET .../effective as the card's view: the range and a row per vendor, nulls kept. */
export function paidEffectiveOf(body) {
  const b = body && typeof body === 'object' ? body : {}
  const vendors = (Array.isArray(b.vendors) ? b.vendors : []).filter((v) => v && typeof v === 'object' && str(v.vendor)).map((v) => {
    /* tokens with a list cost of 0 = no price held (grok, SPL-2461): "not priced", never a $0.00 list price */
    const listPriced = !(num(v.tokens) > 0 && !(num(v.list_cost_usd) > 0))
    return {
      vendor: str(v.vendor),
      status: PAID_STATUSES.includes(v.status) ? v.status : 'list_only',
      tokens: num(v.tokens),
      cacheRead: num(v.cache_read),
      listCostUSD: num(v.list_cost_usd),
      listPerMTok: listPriced ? num(v.list_usd_per_mtok) : null,
      listPriced,
      paidUSD: num(v.paid_usd),
      paidPerDayUSD: num(v.paid_per_day_usd),
      effectivePerMTok: num(v.effective_usd_per_mtok),
    }
  })
  return { from: str(b.from), to: str(b.to), days: Number.isInteger(b.days) ? b.days : 0, vendors }
}

/** An empty form: this UTC month as the period, one unit, USD. */
export function emptyPaidForm(now = new Date()) {
  const y = now.getUTCFullYear()
  const m = now.getUTCMonth()
  const day = (t) => new Date(t).toISOString().slice(0, 10)
  return { vendor: 'claude', kind: 'subscription', planLabel: '', quantity: 1, amount: '', currency: 'USD',
    periodStart: day(Date.UTC(y, m, 1)), periodEnd: day(Date.UTC(y, m + 1, 1)), note: '' }
}

/** A row as the form edits it. */
export function paidFormOf(item) {
  return { vendor: item.vendor, kind: item.kind, planLabel: item.planLabel, quantity: item.quantity, amount: item.amount ?? '',
    currency: item.currency, periodStart: item.periodStart, periodEnd: item.periodEnd, note: item.note }
}

/**
 * The first thing the form may not send, as an i18n key under
 * monitoring.tokens.paid ('' = fine): store.CheckFleetPaidItem's rules, plus
 * a currency the hub holds a rate for (`currencies`; USD always).
 */
export function checkPaidForm(f, currencies = ['USD']) {
  const amount = Number(f.amount)
  const qty = Number(f.quantity)
  const plan = str(f.planLabel).trim()
  const start = dayMs(f.periodStart)
  const end = dayMs(f.periodEnd)
  if (!TOKENS_VENDORS.includes(f.vendor)) return 'err_vendor'
  if (!PAID_KINDS.includes(f.kind)) return 'err_kind'
  if (!plan || plan.length > 100) return 'err_plan'
  if (!Number.isInteger(qty) || qty < 1 || qty > 1000) return 'err_quantity'
  if (f.amount === '' || f.amount === null || !Number.isFinite(amount) || amount <= 0 || amount >= 1e10) return 'err_amount'
  if (!CUR_RE.test(str(f.currency)) || !(f.currency === 'USD' || currencies.includes(f.currency))) return 'err_currency'
  if (!Number.isFinite(start) || !Number.isFinite(end)) return 'err_days'
  if (end <= start) return 'err_end_after_start'
  if (str(f.note).length > 2000) return 'err_note'
  return ''
}

/** The form as the hub's body (POST, or PATCH with every field). */
export function paidBody(f) {
  return { vendor: f.vendor, kind: f.kind, plan_label: str(f.planLabel).trim(), quantity: Number(f.quantity), amount: Number(f.amount),
    currency: f.currency, period_start: f.periodStart, period_end: f.periodEnd, note: str(f.note) }
}

/** The currencies the form offers: USD, then the hub's quotes (GET /v1/tenant/fx/currencies). */
export function paidCurrencies(body) {
  const list = body && Array.isArray(body.currencies) ? body.currencies.filter((c) => CUR_RE.test(str(c))) : []
  return ['USD', ...[...new Set(list)].filter((c) => c !== 'USD').sort()]
}

/** The rows in the hub's list order: period start, then id. */
export function sortPaidItems(rows) {
  const cmp = (x, y) => (x < y ? -1 : x > y ? 1 : 0)
  return (Array.isArray(rows) ? rows : []).slice().sort((a, b) => cmp(a.periodStart, b.periodStart) || cmp(a.id, b.id))
}

/* ---- the mock hub (CI e2e on the mock bundle) ---- */

/** The hub's refusal texts per check (store.CheckFleetPaidItem, hub knownCurrency). */
const HUB_TEXT = Object.freeze({
  err_vendor: 'vendor must be one of ' + TOKENS_VENDORS.join(', '),
  err_kind: 'kind must be subscription or topup',
  err_plan: 'plan_label must be 1..100 characters',
  err_quantity: 'quantity must be 1..1000',
  err_amount: 'amount must be a number above 0',
  err_currency: 'currency must be USD or one the hub holds an exchange rate for',
  err_days: 'period_start and period_end must be UTC days YYYY-MM-DD, the end after the start',
  err_end_after_start: 'period_start and period_end must be UTC days YYYY-MM-DD, the end after the start',
  err_note: 'note must be at most 2000 characters',
})

function mockError(status, token, detail) {
  return Object.assign(new Error(detail), { status, token, detail })
}

function mockStore() {
  try { return typeof localStorage === 'undefined' ? null : localStorage } catch { return null }
}

function mockGate(store) {
  let op = null
  try { op = store ? store.getItem(TOKENS_MOCK_OPERATOR_KEY) : null } catch { /* none */ }
  if (op !== '1') throw Object.assign(mockError(403, 'forbidden', 'only an admin of the operator workspace reads the fleet'), { permission: 'operator.workspaces' })
}

function mockRead(store) {
  try {
    const v = JSON.parse((store && store.getItem(PAID_MOCK_KEY)) || '[]')
    return Array.isArray(v) ? v : []
  } catch { return [] }
}

function mockWrite(store, items) {
  try { if (store) store.setItem(PAID_MOCK_KEY, JSON.stringify(items)) } catch { /* private mode: lost on reload */ }
}

/** The hub's checks of a body: 400 bad_paid_item with the hub's text (or the e2e's, once). */
function mockCheck(b, store) {
  let refuse = null
  try { refuse = store ? store.getItem(PAID_MOCK_REFUSE_KEY) : null } catch { /* none */ }
  if (refuse) {
    try { store.removeItem(PAID_MOCK_REFUSE_KEY) } catch { /* kept */ }
    throw mockError(400, 'bad_paid_item', refuse)
  }
  const f = { vendor: b.vendor, kind: b.kind, planLabel: b.plan_label, quantity: b.quantity, amount: b.amount, currency: b.currency,
    periodStart: b.period_start, periodEnd: b.period_end, note: b.note }
  const why = checkPaidForm(f, Object.keys(PAID_MOCK_FX))
  if (why) throw mockError(400, 'bad_paid_item', HUB_TEXT[why])
}

/** The mock's GET .../paid. */
export function mockPaidList(store = mockStore()) {
  mockGate(store)
  return { items: mockRead(store) }
}

/** The mock's POST .../paid: the item (201). */
export function mockPaidCreate(body, store = mockStore(), now = new Date()) {
  mockGate(store)
  const b = { quantity: 1, note: '', ...body }
  mockCheck(b, store)
  const items = mockRead(store)
  const at = now.toISOString()
  const it = { ...b, id: 'mock-paid-' + now.getTime().toString(36) + '-' + items.length, created_by: 'HUM-1', created_at: at, updated_at: at }
  items.push(it)
  mockWrite(store, items)
  return it
}

/** The mock's PATCH .../paid/{id}: absent fields kept; 404 for no such item. */
export function mockPaidPatch(id, body, store = mockStore(), now = new Date()) {
  mockGate(store)
  const items = mockRead(store)
  const i = items.findIndex((it) => it.id === id)
  if (i < 0) throw mockError(404, 'not_found', 'no paid item ' + id)
  const next = { ...items[i], ...body, id, updated_at: now.toISOString() }
  mockCheck(next, store)
  items[i] = next
  mockWrite(store, items)
  return next
}

/** The mock's DELETE .../paid/{id}: null (204); 404 for no such item. */
export function mockPaidDelete(id, store = mockStore()) {
  mockGate(store)
  const items = mockRead(store)
  if (!items.some((it) => it.id === id)) throw mockError(404, 'not_found', 'no paid item ' + id)
  mockWrite(store, items.filter((it) => it.id !== id))
  return null
}

const cents = (v) => Math.round(v * 1e4) / 1e4

/** One item's USD share of [from, to), or null when it pays for none of it. */
function mockShare(it, from, to) {
  const s = dayMs(it.period_start)
  const e = dayMs(it.period_end)
  const days = Math.round((Math.min(e, to) - Math.max(s, from)) / DAY_MS)
  if (!(days > 0)) return null
  const rate = it.currency === 'USD' ? 1 : PAID_MOCK_FX[it.currency] || 1
  const usd = (it.amount * (it.quantity || 1)) / Math.round((e - s) / DAY_MS) / rate * days
  return { usd, share: { id: it.id, kind: it.kind, plan_label: it.plan_label, days, paid_usd: cents(usd), fx_rate: it.currency === 'USD' ? null : rate, fx_rate_day: null } }
}

/** One vendor's effective row over [from, to) of n days: store.FleetPaidEffective's math. */
function mockVendorRow(vendor, items, from, to, n) {
  const [tok, cache, cost] = MOCK_DAY[vendor] || [0, 0, 0]
  const tokens = tok * n
  const row = { vendor, status: 'list_only', tokens, cache_read: cache * n, list_cost_usd: cents(cost * n),
    list_usd_per_mtok: tokens > 0 ? cents((cost * n) / tokens * 1e6) : null, paid_usd: null, paid_per_day_usd: null, effective_usd_per_mtok: null, items: [] }
  let paid = 0
  for (const it of items.filter((x) => x.vendor === vendor)) {
    const got = mockShare(it, from, to)
    if (!got) continue
    row.items.push(got.share)
    paid += got.usd
  }
  if (!row.items.length) return row
  row.paid_usd = cents(paid)
  row.paid_per_day_usd = cents(paid / n)
  if (tokens === 0) return { ...row, status: 'not_metered' }
  return { ...row, status: 'effective', effective_usd_per_mtok: cents(paid / tokens * 1e6) }
}

/** The mock's GET .../effective: the last 30 whole UTC days before today. */
export function mockPaidEffective(store = mockStore(), now = new Date()) {
  mockGate(store)
  const to = Math.floor(now.getTime() / DAY_MS) * DAY_MS
  const from = to - 30 * DAY_MS
  const items = mockRead(store)
  const day = (t) => new Date(t).toISOString().slice(0, 10)
  return { from: day(from), to: day(to), days: 30, vendors: TOKENS_VENDORS.map((v) => mockVendorRow(v, items, from, to, 30)) }
}

/** A USD price per million tokens ("$2.4937"): 2 to 4 decimals; '—' for none (never a false $0.00). */
export function fmtPerMTok(v, locale = 'en') {
  if (v === null || v === undefined || !Number.isFinite(Number(v)) || Number(v) < 0) return '—'
  try {
    return new Intl.NumberFormat(locale, { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 4 }).format(Number(v))
  } catch {
    return '$' + Number(v).toFixed(4)
  }
}
