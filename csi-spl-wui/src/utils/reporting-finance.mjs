// csi-spl-wui/src/utils/reporting-finance.mjs
//
// Spec 125 row B7 (SPL-4741, case C-NVS-7; owner HUM-10, topic fc0119cd):
// the Reporting Finance tab of the workspace's Netvisor owner. The hub routes
// (B5, csi-spl-doc/doc/md/netvisor-finance-store.md section 5.1):
//   GET  /v1/view/netvisor/forecast    {env, snapshot, items, refresh_requested_at}
//   GET  /v1/view/netvisor/card-costs  {env, snapshot, lines, refresh_requested_at}
//   POST /v1/netvisor/refresh          202 {refresh_requested_at}
//   GET  /v1/netvisor/settings         the settings
//   PUT  /v1/netvisor/settings         {env, bank_account, vat_accounts, tax_accounts, vendor_exclusions}
// The hub answers them to the owner's own browser session only (C7): 403 to
// any other member, admins included, to an act-as clone and to any request
// carrying an Authorization header, so these calls never send the view token.
// The tab is drawn only after the settings read answered 2xx; the hub's 403
// is the control. Amounts are decimal text: sums are integer cents, never a
// float. The mock's figures are invented (C2).

import { mockMeGet, mockRefused } from './act-as-mock.mjs'
import { HUB_READ_TIMEOUT_MS, HUB_WRITE_TIMEOUT_MS } from './fetch-timeouts.mjs'

export const NETVISOR_FORECAST_PATH = '/v1/view/netvisor/forecast'
export const NETVISOR_CARD_COSTS_PATH = '/v1/view/netvisor/card-costs'
export const NETVISOR_REFRESH_PATH = '/v1/netvisor/refresh'
export const NETVISOR_SETTINGS_PATH = '/v1/netvisor/settings'

/** The hub's forecast categories (store.NetvisorForecastCategories), in the card's order. */
export const FINANCE_CATEGORIES = Object.freeze(['bank_balance', 'receivable', 'payable', 'payment', 'payroll', 'vat', 'tax', 'contract'])
/** The card cost slices (spec 125 4.1 item 1). */
export const FINANCE_SLICES = Object.freeze(['vendor', 'cost_type', 'cost_centre'])
/** The hub's settings envs (store.NetvisorEnvs). */
export const FINANCE_ENVS = Object.freeze(['test', 'prd'])
/** A bookkeeping account number as the hub takes it (rdb 0255: 1-12 digits). */
const FINANCE_ACCOUNT_RE = /^[0-9]{1,12}$/

// ---------------------------------------------------------------------------
// the mock hub: invented figures. The owner is the reader with no
// spool.mock.me (every mock page plays the unrestricted reader); any
// spool.mock.me role, admin included, plays another member and gets 403.

const mockState = { settings: null, refreshAt: null }

function mockSettings() {
  if (!mockState.settings) {
    mockState.settings = { owner_human_id: 'HUM-1', env: 'test', bank_account: '9010', vat_accounts: ['9020'], tax_accounts: ['9030'], vendor_exclusions: ['Example Cloud Ltd'], updated_by: 'HUM-1', updated_at: '2026-01-05T08:00:00Z' }
  }
  return mockState.settings
}

function mockGate(method, path, store) {
  if (!mockMeGet(store)) return
  const err = Object.assign(new Error('only the workspace\'s Netvisor owner sees the Netvisor data'), { status: 403, error: 'forbidden' })
  throw method === 'GET' ? mockRefused(path, err) : err
}

const isoDay = (ms) => new Date(ms).toISOString().slice(0, 10)
const isoSecond = (ms) => new Date(ms).toISOString().slice(0, 19) + 'Z'

function mockHead(now) {
  const d = new Date(now)
  const monthEnd = Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)
  return { snapshot_id: 'mock-snapshot-1', env: mockSettings().env, as_of: isoDay(now), month_end: isoDay(monthEnd), newest_bank_voucher_date: isoDay(now - 2 * 86400000), fetched_at: isoSecond(now) }
}

function mockMonth(now, back) {
  const d = new Date(now)
  return isoDay(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - back, 1))
}

/* category, sign, amount, due in days ('' = none), overdue, approved, label */
const MOCK_ITEMS = [
  ['bank_balance', 1, '12000.00', '', false, null, 'Example bank account'],
  ['receivable', 1, '3400.50', '10', false, null, 'Example customer A'],
  ['receivable', 1, '800.00', '-5', true, null, 'Example customer B'],
  ['payable', -1, '1250.25', '7', false, true, 'Example supplier A'],
  ['payable', -1, '300.00', '12', false, false, 'Example supplier B'],
  ['payroll', -1, '4100.00', '20', false, null, 'Example payroll'],
  ['vat', -1, '950.00', '11', false, null, 'Example VAT'],
]

function mockForecast(now) {
  const due = (off) => (off ? isoDay(now + Number(off) * 86400000) : '')
  const items = MOCK_ITEMS.map(([category, sign, amount, off, overdue, approved, label], i) => ({ item_no: i + 1, category, sign, amount, currency: 'EUR', due_date: due(off), overdue, approved, label }))
  return { env: mockSettings().env, snapshot: mockHead(now), items, refresh_requested_at: mockState.refreshAt }
}

/* months back, route, vendor, account number, account name, dimension, item, amount, excluded */
const MOCK_LINES = [
  [0, 'credit_einvoice', 'Example Software Oy', '9101', 'IT software', 'Unit', 'Engineering', '120.00', false],
  [0, 'debit_ledger', 'Example Travel', '9102', 'Travel', 'Unit', 'Sales', '85.40', false],
  [0, 'credit_einvoice', 'Example Cloud Ltd', '9101', 'IT software', 'Unit', 'Engineering', '410.00', true],
  [1, 'credit_einvoice', 'Example Software Oy', '9101', 'IT software', 'Unit', 'Engineering', '120.00', false],
  [1, 'expense_report', 'Example Cafe', '9103', 'Meals', '', '', '23.10', false],
]

function mockCardCosts(now) {
  const lines = MOCK_LINES.map(([back, route, vendor, accountNumber, accountName, dimension, dimensionItem, amount, excluded], i) => ({
    line_no: i + 1, month: mockMonth(now, back), route, vendor, account_number: accountNumber, account_name: accountName,
    dimension, dimension_item: dimensionItem, amount, currency: 'EUR', vat_code: '', excluded,
  }))
  return { env: mockSettings().env, snapshot: mockHead(now), lines, refresh_requested_at: mockState.refreshAt }
}

function mockPutSettings(body, now) {
  if (netvisorSettingsError(body)) throw Object.assign(new Error('bad settings'), { status: 400, error: 'bad_settings' })
  mockState.settings = {
    ...mockSettings(), env: body.env, bank_account: body.bank_account, vat_accounts: [...body.vat_accounts],
    tax_accounts: [...body.tax_accounts], vendor_exclusions: [...body.vendor_exclusions], updated_at: isoSecond(now),
  }
  return mockState.settings
}

/**
 * The mock hub's answer to one call (`store` is a Storage, for the tests).
 * @param {'GET' | 'POST' | 'PUT'} method
 * @param {string} path
 * @param {any} [body]
 * @param {number} [now]
 * @param {Storage} [store]
 */
export function mockNetvisorCall(method, path, body, now = Date.now(), store) {
  mockGate(method, path, store)
  if (method === 'GET' && path === NETVISOR_FORECAST_PATH) return mockForecast(now)
  if (method === 'GET' && path === NETVISOR_CARD_COSTS_PATH) return mockCardCosts(now)
  if (method === 'GET' && path === NETVISOR_SETTINGS_PATH) return mockSettings()
  if (method === 'PUT' && path === NETVISOR_SETTINGS_PATH) return mockPutSettings(body, now)
  if (method === 'POST' && path === NETVISOR_REFRESH_PATH) {
    /* a second press keeps the first time, as the hub */
    if (!mockState.refreshAt) mockState.refreshAt = isoSecond(now)
    return { refresh_requested_at: mockState.refreshAt }
  }
  throw Object.assign(new Error('no such mock route'), { status: 404 })
}

/** Forget the mock's settings and refresh request (the tests). */
export function mockNetvisorReset() {
  mockState.settings = null
  mockState.refreshAt = null
}

// ---------------------------------------------------------------------------
// the hub calls

/**
 * One call to a Netvisor owner route, from the browser session alone: no
 * Authorization header ever (the hub answers 403 person_only to one). Throws
 * { status, error } on a non-2xx answer, { status: 0 } off the network.
 * @param {{ mock?: boolean, base?: string }} api
 * @param {'GET' | 'POST' | 'PUT'} method
 * @param {string} path
 * @param {unknown} [body]
 */
export async function netvisorCall(api, method, path, body) {
  if (api.mock) return Promise.resolve().then(() => mockNetvisorCall(method, path, body))
  const headers = { accept: 'application/json' }
  if (body !== undefined) headers['content-type'] = 'application/json'
  let res
  try {
    res = await fetch(`${String(api.base).replace(/\/+$/, '')}${path}`, {
      method,
      /* the owner's session cookie whatever the view door is */
      credentials: 'include',
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(method === 'GET' ? HUB_READ_TIMEOUT_MS : HUB_WRITE_TIMEOUT_MS),
    })
  } catch {
    throw Object.assign(new Error('network'), { status: 0 })
  }
  const out = await res.json().catch(() => null)
  if (!res.ok) throw Object.assign(new Error(`netvisor ${res.status}`), { status: res.status, error: String(out?.error || '') })
  return out
}

let ownerAnswer = null

/**
 * Is this reader the workspace's Netvisor owner? The settings read answered
 * 2xx; any refusal or failure is false. Asked once per page load.
 * @param {{ mock?: boolean, base?: string }} api
 * @returns {Promise<boolean>}
 */
export function netvisorOwnerProbe(api) {
  if (!ownerAnswer) ownerAnswer = netvisorCall(api, 'GET', NETVISOR_SETTINGS_PATH).then(() => true, () => false)
  return ownerAnswer
}

/** Forget the probe's answer (the tests). */
export function netvisorOwnerProbeReset() {
  ownerAnswer = null
}

// ---------------------------------------------------------------------------
// figures: integer cents from decimal text, never a float

/**
 * "1234.5" / "-12.34" -> cents; null when the text is not a decimal amount.
 * @param {unknown} text
 * @returns {number | null}
 */
export function amountCents(text) {
  const m = /^(-)?([0-9]{1,13})(?:\.([0-9]{1,2}))?$/.exec(String(text ?? '').trim())
  if (!m) return null
  const cents = Number(m[2]) * 100 + Number((m[3] || '').padEnd(2, '0'))
  return m[1] ? -cents : cents
}

/**
 * cents -> "1 234.56" (a narrow no-break space between thousands, "-" first
 * when negative); the locale never changes a figure's digits.
 * @param {number} cents
 */
export function formatCents(cents) {
  const neg = cents < 0
  const abs = Math.abs(Math.round(cents))
  const whole = String(Math.floor(abs / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ')
  return `${neg ? '-' : ''}${whole}.${String(abs % 100).padStart(2, '0')}`
}

/**
 * The forecast card: the signed month-end sum per currency, a subtotal per
 * category in FINANCE_CATEGORIES' order, and the items in the hub's order
 * with their signed cents. An item whose amount is not a decimal, or whose
 * category the WUI has no words for, is left out and counted in `skipped`.
 * @param {{ items?: any[] } | null | undefined} forecast
 */
export function forecastSummary(forecast) {
  const items = Array.isArray(forecast?.items) ? forecast.items : []
  const totals = new Map()
  const byCat = new Map()
  const rows = []
  let skipped = 0
  for (const it of items) {
    const c = amountCents(it?.amount)
    if (c === null || !FINANCE_CATEGORIES.includes(it?.category)) {
      skipped++
      continue
    }
    const signed = (Number(it.sign) < 0 ? -1 : 1) * c
    const cur = String(it.currency || '')
    totals.set(cur, (totals.get(cur) || 0) + signed)
    const key = it.category + '\u0000' + cur
    byCat.set(key, { category: it.category, currency: cur, cents: (byCat.get(key)?.cents || 0) + signed })
    rows.push({ ...it, signedCents: signed })
  }
  const categories = [...byCat.values()].sort((a, b) => FINANCE_CATEGORIES.indexOf(a.category) - FINANCE_CATEGORIES.indexOf(b.category) || a.currency.localeCompare(b.currency))
  return { totals: [...totals.entries()].map(([currency, cents]) => ({ currency, cents })), categories, rows, skipped }
}

/** The group a card cost line falls in for a slice: its key and its words. */
function sliceGroup(line, slice) {
  if (slice === 'cost_type') {
    const no = String(line.account_number || '')
    const name = String(line.account_name || '')
    return { key: no + '\u0000' + name, name: [no, name].filter(Boolean).join(' ') }
  }
  if (slice === 'cost_centre') {
    const dim = String(line.dimension || '')
    const item = String(line.dimension_item || '')
    return { key: dim + '\u0000' + item, name: dim && item ? `${dim}: ${item}` : dim || item }
  }
  const v = String(line.vendor || '').trim()
  return { key: v.toLowerCase(), name: v }
}

/**
 * A line of a spec-123 vendor, counted by the Costs tab already (owner
 * answer Q4 = EXCL): the sync's own mark, or a vendor on the settings'
 * exclusion list.
 * @param {any} line
 * @param {string[]} [exclusions]
 */
export function cardLineExcluded(line, exclusions = []) {
  if (line?.excluded === true) return true
  const v = String(line?.vendor || '').trim().toLowerCase()
  return Boolean(v) && exclusions.some((x) => String(x).trim().toLowerCase() === v)
}

/**
 * Card costs by one slice: one row per month and group, newest month first,
 * the larger sum first within a month; spec-123 vendors are left out of
 * every row and counted in `excluded`. A group with no words has name ''
 * (the page draws its "none" label).
 * @param {{ lines?: any[] } | null | undefined} costs
 * @param {string} slice one of FINANCE_SLICES
 * @param {string[]} [exclusions]
 */
export function cardCostBreakdown(costs, slice, exclusions = []) {
  const lines = Array.isArray(costs?.lines) ? costs.lines : []
  const groups = new Map()
  const excludedTotals = new Map()
  let excludedLines = 0
  for (const line of lines) {
    const c = amountCents(line?.amount)
    if (c === null) continue
    const cur = String(line.currency || '')
    if (cardLineExcluded(line, exclusions)) {
      excludedLines++
      excludedTotals.set(cur, (excludedTotals.get(cur) || 0) + c)
      continue
    }
    const g = sliceGroup(line, slice)
    const month = String(line.month || '').slice(0, 7)
    const key = [month, g.key, cur].join('\u0000')
    const row = groups.get(key) || { month, name: g.name, currency: cur, cents: 0, lines: 0 }
    row.cents += c
    row.lines++
    groups.set(key, row)
  }
  const rows = [...groups.values()].sort((a, b) => b.month.localeCompare(a.month) || b.cents - a.cents || a.name.localeCompare(b.name))
  return { rows, excluded: { lines: excludedLines, totals: [...excludedTotals.entries()].map(([currency, cents]) => ({ currency, cents })) } }
}

// ---------------------------------------------------------------------------
// the settings form

/** A separated list -> its non-empty, trimmed entries. */
function splitList(text, sep = /[\s,;]+/) {
  return String(text ?? '').split(sep).map((x) => x.trim()).filter(Boolean)
}

/**
 * The PUT body from the form's fields: account numbers separated by commas
 * or spaces, one vendor exclusion per line.
 * @param {{ env: string, bank: string, vat: string, tax: string, vendors: string }} form
 */
export function settingsBody(form) {
  return {
    env: String(form.env || ''),
    bank_account: String(form.bank || '').trim(),
    vat_accounts: splitList(form.vat),
    tax_accounts: splitList(form.tax),
    vendor_exclusions: splitList(form.vendors, /\r?\n/),
  }
}

/** The form's fields from the hub's settings. */
export function settingsForm(s) {
  const list = (v) => (Array.isArray(v) ? v.map(String) : [])
  return {
    env: FINANCE_ENVS.includes(s?.env) ? s.env : 'test',
    bank: String(s?.bank_account || ''),
    vat: list(s?.vat_accounts).join(', '),
    tax: list(s?.tax_accounts).join(', '),
    vendors: list(s?.vendor_exclusions).join('\n'),
  }
}

/**
 * The hub's checks on a PUT body (store normNetvisorSettings), before it is
 * sent: the field that fails, or '' when the hub would take it.
 * @param {any} body
 * @returns {'' | 'env' | 'bank_account' | 'vat_accounts' | 'tax_accounts' | 'vendor_exclusions'}
 */
export function netvisorSettingsError(body) {
  if (!FINANCE_ENVS.includes(body?.env)) return 'env'
  if (body.bank_account !== '' && !FINANCE_ACCOUNT_RE.test(String(body.bank_account ?? ''))) return 'bank_account'
  for (const k of /** @type {const} */ (['vat_accounts', 'tax_accounts'])) {
    const list = body[k]
    if (!Array.isArray(list) || list.length > 32 || !list.every((a) => FINANCE_ACCOUNT_RE.test(String(a)))) return k
  }
  const ex = body.vendor_exclusions
  if (!Array.isArray(ex) || ex.length > 200 || ex.reduce((n, v) => n + String(v).length, 0) > 20000) return 'vendor_exclusions'
  return ''
}
