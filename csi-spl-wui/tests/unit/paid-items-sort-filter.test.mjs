// SPL-5198 (owner HUM-10, t1 965283be msg 382450e2: "listing should have
// sorting and filtering simir to the issues listing , it must also have the
// pricess in dollars and euros"): Expenses -> AI costs, the paid items' sort,
// filter row and USD / EUR cells (utils/monitoring-paid.mjs), and the mock
// pricing them as the hub's store.PricePaidItems does.
//
// Run: node tests/unit/paid-items-sort-filter.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  filterPaidItems,
  mockPaidList,
  moneyCell,
  PAID_COLUMNS,
  PAID_MOCK_FX,
  PAID_MOCK_KEY,
  PAID_NO_FILTER,
  paidFilterChoices,
  paidItemsFiltered,
  paidItemsOf,
  paidTotals,
  sortPaidItems,
  sortPaidRows,
} from '../../src/utils/monitoring-paid.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'
import { cycleSort } from '../../src/utils/sheet-sort.mjs'

/* an EUR item, a USD item of 2 seats, an item of a currency with no rate */
const rows = sortPaidItems(paidItemsOf({ items: [
  { id: 'e', vendor: 'mistral', kind: 'subscription', plan_label: 'Le Chat Pro', quantity: 1, amount: 46, currency: 'EUR', period_start: '2026-09-01', period_end: '2026-10-01', note: 'team', usd_micros: 50000000, eur_micros: 46000000 },
  { id: 'u', vendor: 'claude', kind: 'subscription', plan_label: 'Max', quantity: 2, amount: 100, currency: 'USD', period_start: '2026-10-01', period_end: '2026-11-01', note: '', usd_micros: 100000000, eur_micros: 92000000 },
  { id: 'n', vendor: 'grok', kind: 'topup', plan_label: 'Credits', quantity: 1, amount: 7, currency: 'XTS', period_start: '2026-08-15', period_end: '2026-09-15', note: 'no rate', usd_micros: null, eur_micros: null },
] }))
const ids = (list) => list.map((e) => e.id).join(',')

describe('paid items: USD and EUR', () => {
  it('keeps the hub amounts, null when no rate made one (never 0)', () => {
    assert.deepEqual(rows.map((e) => [e.id, e.usdMicros, e.eurMicros]), [['n', null, null], ['e', 50000000, 46000000], ['u', 100000000, 92000000]])
    assert.equal(paidItemsOf({ items: [{ id: 'x', usd_micros: '1' }] })[0].usdMicros, null)
  })
  it('an EUR item: EUR as entered, USD converted; a USD item the other way', () => {
    assert.deepEqual(moneyCell(rows[1], 'EUR'), { amount: 46, converted: false, none: false, day: '', missing: '' })
    assert.deepEqual(moneyCell(rows[1], 'USD'), { amount: 50, converted: true, none: false, day: '', missing: '' })
    assert.deepEqual(moneyCell(rows[2], 'EUR'), { amount: 92, converted: true, none: false, day: '', missing: '' })
  })
  it('a currency without a rate: no amount, said so', () => {
    assert.deepEqual(moneyCell(rows[0], 'EUR'), { amount: null, converted: true, none: true, day: '', missing: 'XTS' })
  })
  it('totals count each item times its quantity; none when an item has no rate', () => {
    assert.deepEqual(paidTotals(rows.slice(1)), { usd: 250, eur: 230 })
    assert.deepEqual(paidTotals(rows), { usd: null, eur: null })
  })
})

describe('paid items: sort', () => {
  it('a header click cycles asc, desc, back to the hub order', () => {
    const s = cycleSort('eur', { col: '', dir: '' }, PAID_COLUMNS)
    assert.deepEqual(s, { col: 'eur', dir: 'asc' })
    assert.equal(ids(sortPaidRows(rows, { col: '', dir: '' })), 'n,e,u')
  })
  it('by each column; an item with no rate sorts last either way', () => {
    assert.equal(ids(sortPaidRows(rows, { col: 'plan', dir: 'asc' })), 'n,e,u')
    assert.equal(ids(sortPaidRows(rows, { col: 'vendor', dir: 'asc' })), 'u,n,e')
    assert.equal(ids(sortPaidRows(rows, { col: 'usd', dir: 'desc' })), 'u,e,n')
    assert.equal(ids(sortPaidRows(rows, { col: 'eur', dir: 'asc' })), 'e,u,n')
    assert.equal(ids(sortPaidRows(rows, { col: 'quantity', dir: 'desc' })), 'u,n,e')
    assert.equal(ids(sortPaidRows(rows, { col: 'period', dir: 'desc' })), 'u,e,n')
  })
})

describe('paid items: filter row', () => {
  it('text in the plan or note, every word', () => {
    assert.equal(ids(filterPaidItems(rows, { text: 'pro TEAM' })), 'e')
    assert.equal(ids(filterPaidItems(rows, { text: 'max zzz' })), '')
  })
  it('vendor, the month the period starts in, and the entered currency', () => {
    assert.equal(ids(filterPaidItems(rows, { vendor: 'claude' })), 'u')
    assert.equal(ids(filterPaidItems(rows, { period: '2026-09' })), 'e')
    assert.equal(ids(filterPaidItems(rows, { currency: 'XTS' })), 'n')
    assert.equal(ids(filterPaidItems(rows, PAID_NO_FILTER)), 'n,e,u')
  })
  it('says when a filter is set, and offers the values the rows hold', () => {
    assert.equal(paidItemsFiltered(PAID_NO_FILTER), false)
    assert.equal(paidItemsFiltered({ vendor: 'grok' }), true)
    assert.deepEqual(paidFilterChoices(rows), { vendor: ['claude', 'grok', 'mistral'], period: ['2026-10', '2026-09', '2026-08'], currency: ['EUR', 'USD', 'XTS'] })
  })
})

describe('paid items: the mock prices as the hub', () => {
  it('USD, EUR and an unrated currency', () => {
    const mem = new Map([[TOKENS_MOCK_OPERATOR_KEY, '1'], [PAID_MOCK_KEY, JSON.stringify([
      { id: 'a', amount: 10, currency: 'USD', period_start: '2026-09-01' },
      { id: 'b', amount: 46, currency: 'EUR', period_start: '2026-09-01' },
      { id: 'c', amount: 7, currency: 'XTS', period_start: '2026-09-01' },
    ])]])
    const store = { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, v), removeItem: (k) => mem.delete(k) }
    const [a, b, c] = mockPaidList(store).items
    assert.deepEqual([a.usd_micros, a.eur_micros], [10000000, Math.round(10000000 * PAID_MOCK_FX.EUR)])
    assert.deepEqual([b.usd_micros, b.eur_micros], [Math.round(46000000 / PAID_MOCK_FX.EUR), 46000000])
    assert.deepEqual([c.usd_micros, c.eur_micros], [null, null])
    /* a converted amount names its rate's day; the mock's rates hold on every day */
    assert.deepEqual([a.usd_rate_day, a.eur_rate_day, b.usd_rate_day, b.eur_rate_day, c.usd_rate_day], [null, '2026-09-01', '2026-09-01', null, null])
  })
})
