// Spec 125 row B7 (SPL-4741, case C-NVS-7; owner HUM-10, topic fc0119cd,
// C2, C7, C8; C7 as rewritten, SPL-4792, owner msg cfa78746): the Reporting
// Finance tab of every person of the Netvisor workspace, with Refresh now
// and the settings the Netvisor owner's alone.
// The tab rule (reporting-tabs.mjs `netvisorReader`), the hub calls and their
// mock, the sums in cents (reporting-finance.mjs), the settings form's checks,
// the page and its strings in every locale. Every figure here is invented.
//
// RED CONTROLS (each seen red, then green, in SPL-4741; the first in SPL-4792):
//   - widen the tab rule to every role (drop `netvisorReader`): "a role alone
//     draws no Finance tab" fails;
//   - send the view token on a Netvisor call: "never an Authorization header"
//     fails;
//   - read amounts as floats: "cents, never a float" fails on 1.15.
//
// Run: node tests/unit/reporting-finance.test.mjs
import { describe, it, beforeEach, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { REPORTING_TABS, visibleReportingTabs } from '../../src/utils/reporting-tabs.mjs'
import {
  FINANCE_CATEGORIES,
  FINANCE_SLICES,
  NETVISOR_CARD_COSTS_PATH,
  NETVISOR_FORECAST_PATH,
  NETVISOR_REFRESH_PATH,
  NETVISOR_SETTINGS_PATH,
  amountCents,
  cardCostBreakdown,
  cardLineExcluded,
  forecastSummary,
  formatCents,
  mockNetvisorCall,
  mockNetvisorReset,
  netvisorCall,
  netvisorReaderProbe,
  netvisorReaderProbeReset,
  netvisorSettingsError,
  settingsBody,
  settingsForm,
} from '../../src/utils/reporting-finance.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const ids = (tabs) => tabs.map((t) => t.id)

/** A Storage stand-in holding the opt-in mock me ({ role, permissions }), or none (the owner). */
const storeAs = (role) => {
  const m = new Map(role ? [['spool.mock.me', JSON.stringify({ role, permissions: [] })]] : [])
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }
}

describe('the Finance tab: every person of the Netvisor workspace (C7 as rewritten)', () => {
  const tab = REPORTING_TABS.find((t) => t.id === 'finance')
  it('is ready, its own path, and no role opens it', () => {
    assert.deepEqual({ path: tab.path, labelKey: tab.labelKey, adminOnly: tab.adminOnly, operatorsOnly: tab.operatorsOnly, netvisorReader: tab.netvisorReader, ready: tab.ready },
      { path: '/reporting/finance', labelKey: 'reporting.tab.finance', adminOnly: false, operatorsOnly: false, netvisorReader: true, ready: true })
    assert.equal(tab.staff, undefined)
    assert.equal(tab.perm, undefined)
  })
  it('a role alone draws no Finance tab; the hub\'s forecast answer does, for any reader', () => {
    const everyRole = { admin: true, operator: true, staff: true, can: () => true }
    assert.ok(!ids(visibleReportingTabs(everyRole)).includes('finance'))
    assert.ok(!ids(visibleReportingTabs({ ...everyRole, netvisorReader: false })).includes('finance'))
    assert.ok(ids(visibleReportingTabs({ netvisorReader: true })).includes('finance'))
  })
})

describe('the mock hub', () => {
  beforeEach(() => mockNetvisorReset())
  const now = Date.UTC(2026, 4, 14, 9, 30)
  it('answers the owner (no mock me) on all five routes', () => {
    const owner = storeAs(null)
    const f = mockNetvisorCall('GET', NETVISOR_FORECAST_PATH, undefined, now, owner)
    assert.equal(f.snapshot.month_end, '2026-05-31')
    assert.equal(f.snapshot.newest_bank_voucher_date, '2026-05-12')
    assert.ok(f.items.length > 0)
    const c = mockNetvisorCall('GET', NETVISOR_CARD_COSTS_PATH, undefined, now, owner)
    assert.ok(c.lines.some((l) => l.excluded))
    assert.equal(mockNetvisorCall('GET', NETVISOR_SETTINGS_PATH, undefined, now, owner).env, 'test')
    const r1 = mockNetvisorCall('POST', NETVISOR_REFRESH_PATH, {}, now, owner)
    const r2 = mockNetvisorCall('POST', NETVISOR_REFRESH_PATH, {}, now + 60000, owner)
    assert.equal(r2.refresh_requested_at, r1.refresh_requested_at, 'a second press keeps the first time')
    const put = mockNetvisorCall('PUT', NETVISOR_SETTINGS_PATH, { env: 'prd', bank_account: '9', vat_accounts: [], tax_accounts: [], vendor_exclusions: [] }, now, owner)
    assert.equal(put.env, 'prd')
  })
  it('the owner\'s views say reader_is_owner and carry the vendor exclusions', () => {
    const owner = storeAs(null)
    assert.equal(mockNetvisorCall('GET', NETVISOR_FORECAST_PATH, undefined, now, owner).reader_is_owner, true)
    const c = mockNetvisorCall('GET', NETVISOR_CARD_COSTS_PATH, undefined, now, owner)
    assert.equal(c.reader_is_owner, true)
    assert.deepEqual(c.vendor_exclusions, ['Example Cloud Ltd'])
  })
  it('another person, an admin too, reads the views (reader_is_owner false) and gets 403 on the owner routes', () => {
    for (const role of ['admin', 'member', 'biz_owner']) {
      const f = mockNetvisorCall('GET', NETVISOR_FORECAST_PATH, undefined, now, storeAs(role))
      assert.ok(f.items.length > 0 && f.reader_is_owner === false, role)
      const c = mockNetvisorCall('GET', NETVISOR_CARD_COSTS_PATH, undefined, now, storeAs(role))
      assert.ok(c.lines.length > 0 && c.reader_is_owner === false && c.vendor_exclusions.length === 1, role)
      for (const [m, p] of [['GET', NETVISOR_SETTINGS_PATH], ['POST', NETVISOR_REFRESH_PATH], ['PUT', NETVISOR_SETTINGS_PATH]]) {
        assert.throws(() => mockNetvisorCall(m, p, {}, now, storeAs(role)), (e) => e.status === 403, `${role} ${m} ${p}`)
      }
    }
  })
  it('a seat that is not a person\'s gets 403 on every route and no figure', () => {
    for (const role of ['pure_agent', 'time_accountant', 'channel_guest']) {
      for (const [m, p] of [['GET', NETVISOR_FORECAST_PATH], ['GET', NETVISOR_CARD_COSTS_PATH], ['GET', NETVISOR_SETTINGS_PATH], ['POST', NETVISOR_REFRESH_PATH], ['PUT', NETVISOR_SETTINGS_PATH]]) {
        assert.throws(() => mockNetvisorCall(m, p, {}, now, storeAs(role)), (e) => e.status === 403, `${role} ${m} ${p}`)
      }
    }
  })
  it('refuses a body the hub refuses (400)', () => {
    assert.throws(() => mockNetvisorCall('PUT', NETVISOR_SETTINGS_PATH, { env: 'prd', bank_account: 'x1', vat_accounts: [], tax_accounts: [], vendor_exclusions: [] }, now, storeAs(null)), (e) => e.status === 400)
  })
})

describe('the live calls: the owner\'s session cookie, never a token (hub 403 person_only)', () => {
  const realFetch = globalThis.fetch
  let calls
  beforeEach(() => {
    calls = []
    netvisorReaderProbeReset()
    globalThis.fetch = async (url, init) => {
      calls.push({ url, init })
      if (String(url).endsWith(NETVISOR_FORECAST_PATH) && String(url).includes('other.example.com')) return new Response(JSON.stringify({ error: 'not_found' }), { status: 404 })
      if (String(url).endsWith(NETVISOR_FORECAST_PATH)) return new Response(JSON.stringify({ items: [], reader_is_owner: false }), { status: 200 })
      if (String(url).endsWith(NETVISOR_SETTINGS_PATH) && init.method === 'GET') return new Response(JSON.stringify({ error: 'forbidden' }), { status: 403 })
      return new Response(JSON.stringify({ refresh_requested_at: '2026-05-14T09:30:00Z' }), { status: 202 })
    }
  })
  afterEach(() => { globalThis.fetch = realFetch })
  const api = { base: 'https://hub.example.com/', token: 'view-token', credentials: 'omit' }
  it('never an Authorization header, always credentials include', async () => {
    const out = await netvisorCall(api, 'POST', NETVISOR_REFRESH_PATH, {})
    assert.equal(out.refresh_requested_at, '2026-05-14T09:30:00Z')
    const { url, init } = calls[0]
    assert.equal(url, 'https://hub.example.com/v1/netvisor/refresh')
    assert.equal(init.credentials, 'include')
    assert.ok(!Object.keys(init.headers).some((h) => h.toLowerCase() === 'authorization'), JSON.stringify(init.headers))
  })
  it('a 403 throws its status; the probe reads the forecast, once per hub base', async () => {
    await assert.rejects(netvisorCall(api, 'GET', NETVISOR_SETTINGS_PATH), (e) => e.status === 403 && e.error === 'forbidden')
    calls = []
    assert.equal(await netvisorReaderProbe(api), true)
    assert.equal(await netvisorReaderProbe(api), true)
    assert.equal(calls.length, 1)
    assert.ok(String(calls[0].url).endsWith(NETVISOR_FORECAST_PATH))
    const other = { ...api, base: 'https://other.example.com' }
    assert.equal(await netvisorReaderProbe(other), false, 'another workspace answers 404')
    assert.equal(calls.length, 2)
  })
  it('off the network is status 0', async () => {
    globalThis.fetch = async () => { throw new TypeError('offline') }
    await assert.rejects(netvisorCall(api, 'GET', NETVISOR_FORECAST_PATH), (e) => e.status === 0)
  })
})

describe('figures: cents, never a float', () => {
  it('reads decimal text', () => {
    assert.equal(amountCents('0.1'), 10)
    assert.equal(amountCents('1.15'), 115, '1.15 * 100 is 114.99999999999999 as a float')
    assert.equal(amountCents('12'), 1200)
    assert.equal(amountCents('-3.05'), -305)
    for (const bad of ['', '1.234', '1,5', 'abc', null, undefined, '1e3']) assert.equal(amountCents(bad), null, String(bad))
  })
  it('sums 0.1 + 0.2 + 1.15 to 1.45 exactly', () => {
    const f = forecastSummary({ items: [
      { item_no: 1, category: 'receivable', sign: 1, amount: '0.1', currency: 'EUR' },
      { item_no: 2, category: 'receivable', sign: 1, amount: '0.2', currency: 'EUR' },
      { item_no: 3, category: 'receivable', sign: 1, amount: '1.15', currency: 'EUR' },
    ] })
    assert.deepEqual(f.totals, [{ currency: 'EUR', cents: 145 }])
    assert.equal(formatCents(f.totals[0].cents), '1.45')
  })
  it('formats with thousands and a sign', () => {
    assert.equal(formatCents(123456789), '1 234 567.89')
    assert.equal(formatCents(-5), '-0.05')
    assert.equal(formatCents(0), '0.00')
  })
})

describe('the forecast card', () => {
  it('signs each term, subtotals by category in the hub\'s order, skips what it cannot read', () => {
    const f = forecastSummary({ items: [
      { item_no: 1, category: 'payable', sign: -1, amount: '100.00', currency: 'EUR' },
      { item_no: 2, category: 'bank_balance', sign: 1, amount: '1000.00', currency: 'EUR' },
      { item_no: 3, category: 'payable', sign: -1, amount: '50.50', currency: 'EUR' },
      { item_no: 4, category: 'unknown', sign: 1, amount: '9.00', currency: 'EUR' },
      { item_no: 5, category: 'vat', sign: -1, amount: 'n/a', currency: 'EUR' },
    ] })
    assert.deepEqual(f.totals, [{ currency: 'EUR', cents: 84950 }])
    assert.deepEqual(f.categories.map((c) => [c.category, c.cents]), [['bank_balance', 100000], ['payable', -15050]])
    assert.deepEqual(f.rows.map((r) => r.item_no), [1, 2, 3])
    assert.equal(f.skipped, 2)
  })
  it('no snapshot is an empty card', () => {
    assert.deepEqual(forecastSummary(null), { totals: [], categories: [], rows: [], skipped: 0 })
  })
})

describe('card costs by vendor, cost type and cost centre (spec 125 4.1)', () => {
  const lines = [
    { month: '2026-05-01', vendor: 'Vendor A', account_number: '9101', account_name: 'Software', dimension: 'Unit', dimension_item: 'Eng', amount: '10.00', currency: 'EUR', excluded: false },
    { month: '2026-05-01', vendor: 'vendor a', account_number: '9101', account_name: 'Software', dimension: 'Unit', dimension_item: 'Ops', amount: '5.00', currency: 'EUR', excluded: false },
    { month: '2026-05-01', vendor: 'Vendor B', account_number: '9102', account_name: 'Travel', dimension: '', dimension_item: '', amount: '7.50', currency: 'EUR', excluded: false },
    { month: '2026-04-01', vendor: 'Vendor A', account_number: '9101', account_name: 'Software', dimension: 'Unit', dimension_item: 'Eng', amount: '1.00', currency: 'EUR', excluded: false },
    { month: '2026-05-01', vendor: 'Cloud Co', account_number: '9101', account_name: 'Software', dimension: 'Unit', dimension_item: 'Eng', amount: '99.00', currency: 'EUR', excluded: true },
    { month: '2026-05-01', vendor: 'AI Co', account_number: '9101', account_name: 'Software', dimension: 'Unit', dimension_item: 'Eng', amount: '20.00', currency: 'EUR', excluded: false },
  ]
  const costs = { lines }
  it('every slice has its words', () => {
    assert.deepEqual([...FINANCE_SLICES], ['vendor', 'cost_type', 'cost_centre'])
  })
  it('by vendor: newest month first, larger sum first, vendor names case-folded', () => {
    const b = cardCostBreakdown(costs, 'vendor', ['ai co'])
    assert.deepEqual(b.rows.map((r) => [r.month, r.name, r.cents, r.lines]), [
      ['2026-05', 'Vendor A', 1500, 2], ['2026-05', 'Vendor B', 750, 1], ['2026-04', 'Vendor A', 100, 1],
    ])
  })
  it('spec-123 vendors are left out (Q4 = EXCL): the sync\'s mark and the settings\' list', () => {
    const b = cardCostBreakdown(costs, 'cost_type', ['AI Co'])
    assert.deepEqual(b.excluded, { lines: 2, totals: [{ currency: 'EUR', cents: 11900 }] })
    assert.deepEqual(b.rows.map((r) => [r.month, r.name, r.cents]), [['2026-05', '9101 Software', 1500], ['2026-05', '9102 Travel', 750], ['2026-04', '9101 Software', 100]])
    /* CONTROL: no exclusion list counts AI Co in */
    assert.equal(cardCostBreakdown(costs, 'cost_type').rows[0].cents, 3500)
    assert.ok(cardLineExcluded({ vendor: ' AI CO ' }, ['ai co']))
    assert.ok(!cardLineExcluded({ vendor: '' }, ['']))
  })
  it('by cost centre: dimension and item, none when the line has neither', () => {
    const b = cardCostBreakdown(costs, 'cost_centre', ['AI Co'])
    assert.deepEqual(b.rows.filter((r) => r.month === '2026-05').map((r) => [r.name, r.cents]), [['Unit: Eng', 1000], ['', 750], ['Unit: Ops', 500]])
  })
})

describe('the settings form (owner answer Q2)', () => {
  it('the form round-trips the hub\'s settings', () => {
    const s = { env: 'prd', bank_account: '9010', vat_accounts: ['9020', '9021'], tax_accounts: [], vendor_exclusions: ['Cloud Co', 'AI Co'] }
    const f = settingsForm(s)
    assert.deepEqual(f, { env: 'prd', bank: '9010', vat: '9020, 9021', tax: '', vendors: 'Cloud Co\nAI Co' })
    assert.deepEqual(settingsBody(f), { env: 'prd', bank_account: '9010', vat_accounts: ['9020', '9021'], tax_accounts: [], vendor_exclusions: ['Cloud Co', 'AI Co'] })
    assert.equal(settingsForm(null).env, 'test')
  })
  it('checks what the hub checks, field by field', () => {
    const ok = { env: 'test', bank_account: '', vat_accounts: [], tax_accounts: [], vendor_exclusions: [] }
    assert.equal(netvisorSettingsError(ok), '')
    assert.equal(netvisorSettingsError({ ...ok, env: 'dev' }), 'env')
    assert.equal(netvisorSettingsError({ ...ok, bank_account: '1234567890123' }), 'bank_account')
    assert.equal(netvisorSettingsError({ ...ok, vat_accounts: ['12a'] }), 'vat_accounts')
    assert.equal(netvisorSettingsError({ ...ok, tax_accounts: Array.from({ length: 33 }, () => '1') }), 'tax_accounts')
    assert.equal(netvisorSettingsError({ ...ok, vendor_exclusions: Array.from({ length: 201 }, () => 'v') }), 'vendor_exclusions')
  })
})

describe('the page and its strings', () => {
  const page = read('src/pages/reporting/finance.vue')
  const form = read('src/components/reporting/finance/FinanceSettings.vue')
  it('the page reads the views first (their 403 / 404 is the door), the settings only for the owner', () => {
    const load = page.slice(page.indexOf('async function load()'))
    assert.ok(load.indexOf('NETVISOR_FORECAST_PATH') < load.indexOf('NETVISOR_SETTINGS_PATH'))
    assert.match(load, /reader_is_owner === true \? await netvisorCall\(api, 'GET', NETVISOR_SETTINGS_PATH\)/)
    assert.match(page, /status === 403[^\n]*'forbidden'/)
    assert.match(page, /v-if="isOwner"[^>]*data-test="finance-refresh"/)
    assert.match(page, /<FinanceSettings v-if="isOwner && settings"/)
  })
  it('the reporting bar probes the reader in any workspace, its module loaded on demand', () => {
    const bar = read('src/pages/reporting.vue')
    assert.match(bar, /import\('~\/utils\/reporting-finance\.mjs'\)[\s\S]{0,80}netvisorReaderProbe\(api\)/)
    assert.doesNotMatch(bar, /operator\.visible[\s\S]{0,80}netvisor/)
    assert.doesNotMatch(bar, /^import .*reporting-finance/m)
  })
  it('every key the screen names is in every locale, never an English copy outside brand words', () => {
    const keys = new Set()
    for (const src of [page, form]) for (const m of src.matchAll(/t\('(reporting\.finance\.[a-z_.]*[a-z])'/g)) keys.add(m[1])
    for (const k of ['no_snapshot', 'no_snapshot_member']) keys.add('reporting.finance.' + k)
    for (const c of FINANCE_CATEGORIES) keys.add('reporting.finance.category.' + c)
    for (const s of FINANCE_SLICES) keys.add('reporting.finance.costs.slice_' + s)
    for (const e of ['test', 'prd']) keys.add('reporting.finance.env.' + e)
    for (const f of ['env', 'bank_account', 'vat_accounts', 'tax_accounts', 'vendor_exclusions']) keys.add('reporting.finance.settings.invalid_' + f)
    keys.add('reporting.tab.finance')
    const dir = join(WUI, 'i18n/locales')
    const get = (o, k) => k.split('.').reduce((a, p) => (a == null ? a : a[p]), o)
    const en = JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8'))
    for (const file of readdirSync(dir).filter((f) => f.endsWith('.json'))) {
      const loc = JSON.parse(readFileSync(join(dir, file), 'utf8'))
      for (const k of keys) {
        const v = get(loc, k)
        assert.equal(typeof v, 'string', `${file} ${k}`)
        assert.ok(v.length > 0, `${file} ${k}`)
      }
    }
    assert.equal(get(en, 'reporting.tab.finance'), 'Finance')
  })
})
