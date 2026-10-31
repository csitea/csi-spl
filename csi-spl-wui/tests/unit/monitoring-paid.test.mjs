// Spec 140 3.8 (SPL-2567): the Tokens page's Paid card, the util under it
// (src/utils/monitoring-paid.mjs): the hub's bodies as rows and views (a
// null price stays null), the form's checks (store.CheckFleetPaidItem's
// rules: the end after the start, an amount above 0, a known currency), the
// body sent, and the mock hub the e2e drives (403 unless operator admin,
// add, edit, delete, the effective math of store.FleetPaidEffective).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  PAID_MOCK_FX,
  PAID_MOCK_KEY,
  PAID_MOCK_REFUSE_KEY,
  checkPaidForm,
  dayMs,
  emptyPaidForm,
  fmtPerMTok,
  mockPaidCreate,
  mockPaidDelete,
  mockPaidEffective,
  mockPaidList,
  mockPaidPatch,
  paidBody,
  paidCurrencies,
  paidEffectiveOf,
  paidFormOf,
  paidItemsOf,
  sortPaidItems,
} from '../../src/utils/monitoring-paid.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'
import { MOCK_FX_RATES } from '../../src/utils/tenant-costs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (p) => readFileSync(join(WUI, p), 'utf8')

function memStore(operator = true) {
  const m = new Map(operator ? [[TOKENS_MOCK_OPERATOR_KEY, '1']] : [])
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }
}

const GOOD = { vendor: 'claude', kind: 'subscription', planLabel: 'Max 20x', quantity: 3, amount: '200', currency: 'USD',
  periodStart: '2026-10-01', periodEnd: '2026-11-01', note: '' }

describe('monitoring-paid: hub bodies', () => {
  it('paidItemsOf maps the wire fields and drops rows with no id', () => {
    const rows = paidItemsOf({ items: [
      { id: 'a', vendor: 'grok', kind: 'topup', plan_label: 'credits', quantity: 2, amount: 25.5, currency: 'EUR', period_start: '2026-10-01', period_end: '2026-10-15', note: 'x' },
      { vendor: 'claude' }, null, 'junk',
    ] })
    assert.deepEqual(rows, [{ id: 'a', vendor: 'grok', kind: 'topup', planLabel: 'credits', quantity: 2, amount: 25.5, currency: 'EUR',
      periodStart: '2026-10-01', periodEnd: '2026-10-15', note: 'x' }])
    assert.deepEqual(paidItemsOf(null), [])
    assert.deepEqual(paidItemsOf({ items: 'no' }), [])
  })

  it('paidEffectiveOf keeps nulls null and an unknown status as list_only', () => {
    const v = paidEffectiveOf({ from: '2026-09-19', to: '2026-10-19', days: 30, vendors: [
      { vendor: 'agy', status: 'not_metered', tokens: 0, cache_read: 0, list_cost_usd: 0, list_usd_per_mtok: null, paid_usd: 250, paid_per_day_usd: 8.3333, effective_usd_per_mtok: null },
      { vendor: 'claude', status: 'weird', tokens: 10, list_usd_per_mtok: 2.5, paid_usd: null },
    ] })
    assert.equal(v.days, 30)
    assert.equal(v.vendors[0].status, 'not_metered')
    assert.equal(v.vendors[0].effectivePerMTok, null)
    assert.equal(v.vendors[0].listPerMTok, null)
    assert.equal(v.vendors[0].paidPerDayUSD, 8.3333)
    assert.equal(v.vendors[1].status, 'list_only')
    assert.equal(v.vendors[1].paidUSD, null)
  })

  it('paidEffectiveOf: tokens with a list cost of 0 are not priced, never a $0.00 list price', () => {
    const v = paidEffectiveOf({ vendors: [
      { vendor: 'grok', status: 'list_only', tokens: 27000000, list_cost_usd: 0, list_usd_per_mtok: 0 },
      { vendor: 'qwen', status: 'list_only', tokens: 0, list_cost_usd: 0, list_usd_per_mtok: null },
      { vendor: 'claude', status: 'list_only', tokens: 10, list_cost_usd: 0.5, list_usd_per_mtok: 50000 },
    ] }).vendors
    assert.deepEqual(v.map((r) => [r.vendor, r.listPriced, r.listPerMTok]), [['grok', false, null], ['qwen', true, null], ['claude', true, 50000]])
  })

  it('paidCurrencies puts USD first, then the hub quotes sorted, junk dropped', () => {
    assert.deepEqual(paidCurrencies({ default: 'EUR', currencies: ['SEK', 'EUR', 'usd', 'USD', 'EUR'] }), ['USD', 'EUR', 'SEK'])
    assert.deepEqual(paidCurrencies(null), ['USD'])
  })

  it('sortPaidItems orders by period start, then id', () => {
    const rows = [{ id: 'b', periodStart: '2026-10-01' }, { id: 'c', periodStart: '2026-09-01' }, { id: 'a', periodStart: '2026-10-01' }]
    assert.deepEqual(sortPaidItems(rows).map((r) => r.id), ['c', 'a', 'b'])
  })

  it('fmtPerMTok shows up to 4 decimals and a dash for none, never $0.00', () => {
    assert.equal(fmtPerMTok(2.49371), '$2.4937')
    assert.equal(fmtPerMTok(3), '$3.00')
    assert.equal(fmtPerMTok(null), '—')
    assert.equal(fmtPerMTok(undefined), '—')
  })
})

describe('monitoring-paid: the form', () => {
  it('a good form passes and becomes the hub body', () => {
    assert.equal(checkPaidForm(GOOD), '')
    assert.deepEqual(paidBody({ ...GOOD, planLabel: '  Max 20x ' }), { vendor: 'claude', kind: 'subscription', plan_label: 'Max 20x', quantity: 3,
      amount: 200, currency: 'USD', period_start: '2026-10-01', period_end: '2026-11-01', note: '' })
  })

  it('names the first problem as an i18n key', () => {
    const cases = [
      [{ vendor: 'openai' }, 'err_vendor'],
      [{ kind: 'gift' }, 'err_kind'],
      [{ planLabel: '   ' }, 'err_plan'],
      [{ planLabel: 'x'.repeat(101) }, 'err_plan'],
      [{ quantity: 0 }, 'err_quantity'],
      [{ quantity: 1.5 }, 'err_quantity'],
      [{ amount: '' }, 'err_amount'],
      [{ amount: '0' }, 'err_amount'],
      [{ amount: '-5' }, 'err_amount'],
      [{ amount: 'abc' }, 'err_amount'],
      [{ currency: 'EUR' }, 'err_currency'],
      [{ currency: 'usd' }, 'err_currency'],
      [{ periodStart: '' }, 'err_days'],
      [{ periodEnd: '2026-02-30' }, 'err_days'],
      [{ periodEnd: '2026-10-01' }, 'err_end_after_start'],
      [{ periodEnd: '2026-09-30' }, 'err_end_after_start'],
      [{ note: 'n'.repeat(2001) }, 'err_note'],
    ]
    for (const [patch, want] of cases) assert.equal(checkPaidForm({ ...GOOD, ...patch }), want, JSON.stringify(patch))
  })

  it('a currency the hub quotes passes', () => {
    assert.equal(checkPaidForm({ ...GOOD, currency: 'EUR' }, ['USD', 'EUR']), '')
  })

  it('dayMs refuses a day that does not exist', () => {
    assert.ok(Number.isFinite(dayMs('2028-02-29')))
    assert.ok(Number.isNaN(dayMs('2026-02-29')))
    assert.ok(Number.isNaN(dayMs('2026-1-01')))
  })

  it('the empty form is this UTC month, valid once named and priced', () => {
    const f = emptyPaidForm(new Date('2026-12-15T23:30:00Z'))
    assert.equal(f.periodStart, '2026-12-01')
    assert.equal(f.periodEnd, '2027-01-01')
    assert.equal(checkPaidForm(f), 'err_plan')
    assert.equal(checkPaidForm({ ...f, planLabel: 'p', amount: '1' }), '')
  })

  it('paidFormOf round-trips a row', () => {
    const row = paidItemsOf({ items: [{ id: 'a', vendor: 'qwen', kind: 'topup', plan_label: 'p', quantity: 1, amount: 9, currency: 'USD', period_start: '2026-10-01', period_end: '2026-10-02', note: '' }] })[0]
    assert.equal(checkPaidForm(paidFormOf(row)), '')
    assert.equal(paidBody(paidFormOf(row)).amount, 9)
  })
})

describe('monitoring-paid: the mock hub', () => {
  it('answers 403 operator.workspaces unless the e2e opted into the operator admin', () => {
    const s = memStore(false)
    for (const call of [() => mockPaidList(s), () => mockPaidEffective(s), () => mockPaidCreate(paidBody(GOOD), s), () => mockPaidDelete('x', s)]) {
      assert.throws(call, (e) => e.status === 403 && e.permission === 'operator.workspaces')
    }
  })

  it('add, edit, delete: the list follows, a bad edit is refused with the hub text', () => {
    const s = memStore()
    assert.deepEqual(mockPaidList(s).items, [])
    const it1 = mockPaidCreate(paidBody(GOOD), s, new Date('2026-10-19T10:00:00Z'))
    assert.ok(it1.id)
    assert.equal(JSON.parse(s.getItem(PAID_MOCK_KEY)).length, 1)
    const ed = mockPaidPatch(it1.id, { amount: 180, plan_label: 'Max 5x' }, s)
    assert.equal(ed.amount, 180)
    assert.equal(mockPaidList(s).items[0].plan_label, 'Max 5x')
    assert.throws(() => mockPaidPatch(it1.id, { period_end: '2026-09-01' }, s),
      (e) => e.status === 400 && e.detail === 'period_start and period_end must be UTC days YYYY-MM-DD, the end after the start')
    assert.throws(() => mockPaidCreate({ ...paidBody(GOOD), currency: 'XYZ' }, s), (e) => e.status === 400 && /exchange rate/.test(e.detail))
    assert.throws(() => mockPaidPatch('nope', {}, s), (e) => e.status === 404)
    assert.equal(mockPaidDelete(it1.id, s), null)
    assert.deepEqual(mockPaidList(s).items, [])
    assert.throws(() => mockPaidDelete(it1.id, s), (e) => e.status === 404)
  })

  it('effective: spread over the item days, list_only / effective / not_metered as the hub', () => {
    const s = memStore()
    const now = new Date('2026-10-19T12:00:00Z')
    /* 300 USD for 30 days, all inside the read's range 2026-09-19..2026-10-19 */
    mockPaidCreate({ ...paidBody(GOOD), quantity: 1, amount: 300, period_start: '2026-09-19', period_end: '2026-10-19' }, s, now)
    /* agy: paid, no tokens logged; 60 days, half inside the range */
    mockPaidCreate({ ...paidBody(GOOD), vendor: 'agy', quantity: 1, amount: 120, period_start: '2026-10-04', period_end: '2026-12-03' }, s, now)
    const v = paidEffectiveOf(mockPaidEffective(s, now))
    assert.equal(v.from, '2026-09-19')
    assert.equal(v.to, '2026-10-19')
    const by = Object.fromEntries(v.vendors.map((r) => [r.vendor, r]))
    assert.deepEqual(Object.keys(by), ['claude', 'mistral', 'grok', 'agy', 'qwen'])
    assert.equal(by.claude.status, 'effective')
    assert.equal(by.claude.paidUSD, 300)
    assert.equal(by.claude.paidPerDayUSD, 10)
    assert.equal(by.claude.effectivePerMTok, Math.round(300 / (15800000 * 30) * 1e6 * 1e4) / 1e4)
    assert.ok(by.claude.listPerMTok > 0)
    assert.equal(by.agy.status, 'not_metered')
    assert.equal(by.agy.paidUSD, 30)
    assert.equal(by.agy.effectivePerMTok, null)
    assert.equal(by.mistral.status, 'list_only')
    assert.equal(by.mistral.paidUSD, null)
  })

  it('the e2e refusal hook refuses the next write once with its text', () => {
    const s = memStore()
    s.setItem(PAID_MOCK_REFUSE_KEY, 'currency must be USD or one the hub holds an exchange rate for')
    assert.throws(() => mockPaidCreate(paidBody(GOOD), s), (e) => e.status === 400 && e.token === 'bad_paid_item' && /exchange rate/.test(e.detail))
    assert.equal(s.getItem(PAID_MOCK_REFUSE_KEY), null)
    assert.ok(mockPaidCreate(paidBody(GOOD), s).id)
  })

  it('the mock converts a non-USD item at its rate', () => {
    const s = memStore()
    const now = new Date('2026-10-19T12:00:00Z')
    mockPaidCreate({ ...paidBody(GOOD), vendor: 'mistral', quantity: 1, amount: 92, currency: 'EUR', period_start: '2026-09-19', period_end: '2026-10-19' }, s, now)
    const m = paidEffectiveOf(mockPaidEffective(s, now)).vendors.find((r) => r.vendor === 'mistral')
    assert.equal(m.paidUSD, 100)
  })

  it('the mock rates are the costs mock rates (the currencies the form offers in the mock)', () => {
    assert.deepEqual({ ...PAID_MOCK_FX }, { ...MOCK_FX_RATES })
  })
})

describe('monitoring-paid: the page wiring', () => {
  it('Expenses -> AI costs loads the Paid card as its own chunk, wrapped off a bare v-if (SPL-4382)', () => {
    const page = src('src/pages/expenses/ai.vue')
    assert.match(page, /defineAsyncComponent\(\(\) => import\('~\/components\/monitoring\/token-burn\/PaidItemsCard\.vue'\)\)/)
    assert.match(page, /<div class="tk-lazy"><PaidItemsCard \/><\/div>/)
    assert.doesNotMatch(page, /^import PaidItemsCard/m)
  })

  it('the Tokens page no longer mounts the card; it links to Expenses -> AI costs (SPL-4382)', () => {
    const page = src('src/pages/monitoring/tokens/index.vue')
    assert.doesNotMatch(page, /PaidItemsCard/)
    assert.match(page, /<NuxtLink :to="localePath\(EXPENSES_DEFAULT_PATH\)" data-test="tokens-paid-link">\{\{ t\('expenses\.tokens_link'\) \}\}<\/NuxtLink>/)
  })

  it('no inline :style in the paid components (CSP)', () => {
    for (const f of ['PaidItemsCard.vue', 'PaidItemForm.vue', 'EffectivePriceTable.vue']) {
      assert.doesNotMatch(src('src/components/monitoring/token-burn/' + f), /:style=|\sstyle="/, f)
    }
  })
})
