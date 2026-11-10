// SPL-5198 (owner HUM-10, t1 965283be msg 382450e2: "listing should have
// sorting and filtering simir to the issues listing , it must also have the
// pricess in dollars and euros"): the Expenses lists' sort, filter row and
// USD / EUR cells (utils/cost-entries.mjs), and the mock pricing the rows as
// the hub's store.PriceCostEntries does.
//
// Run: node tests/unit/cost-entries-sort-filter.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  COST_ENTRIES_MOCK_KEY,
  COST_ENTRY_COLUMNS,
  COST_ENTRY_NO_FILTER,
  costEntriesFiltered,
  costEntriesOf,
  costEntryCell,
  costEntryFilterChoices,
  costEntryTotals,
  filterCostEntries,
  mockCostEntryList,
  sortCostEntries,
} from '../../src/utils/cost-entries.mjs'
import { MOCK_FX_RATES } from '../../src/utils/tenant-costs.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'
import { cycleSort } from '../../src/utils/sheet-sort.mjs'

/* an EUR row, a USD row, a row of a month with no rate (XTS) */
const rows = costEntriesOf({ entries: [
  { id: 'e', type: 'cloud', label: 'Workspace invoice', amount: 64.8, currency: 'EUR', period: '2026-09', note: 'net', usd_micros: 72000000, eur_micros: 64800000, usd_rate_day: '2026-08-29', eur_rate_day: null },
  { id: 'u', type: 'cloud', label: 'GitHub', amount: 10, currency: 'USD', period: '2026-09', note: '', usd_micros: 10000000, eur_micros: 9000000, usd_rate_day: null, eur_rate_day: '2026-09-01' },
  { id: 'n', type: 'cloud', label: 'Old hosting', amount: 7, currency: 'XTS', period: '2026-07', note: 'no rate', usd_micros: null, eur_micros: null },
] })
const ids = (list) => list.map((e) => e.id).join(',')

describe('cost entries: USD and EUR', () => {
  it('keeps the hub amounts, null when no rate made one (never 0)', () => {
    assert.deepEqual(rows.map((e) => [e.usdMicros, e.eurMicros]), [[72000000, 64800000], [10000000, 9000000], [null, null]])
    assert.equal(costEntriesOf({ entries: [{ id: 'x', usd_micros: 'a' }] })[0].usdMicros, null)
  })
  it('an EUR row: EUR as entered, USD converted', () => {
    assert.deepEqual(costEntryCell(rows[0], 'EUR'), { amount: 64.8, converted: false, none: false, day: '', missing: '' })
    /* SPL-5198 R7 W2: the day of the rate used, not the row's month */
    assert.deepEqual(costEntryCell(rows[0], 'USD'), { amount: 72, converted: true, none: false, day: '2026-08-29', missing: '' })
  })
  it('a USD row: USD as entered, EUR converted', () => {
    assert.deepEqual(costEntryCell(rows[1], 'USD'), { amount: 10, converted: false, none: false, day: '', missing: '' })
    assert.deepEqual(costEntryCell(rows[1], 'EUR'), { amount: 9, converted: true, none: false, day: '2026-09-01', missing: '' })
  })
  it('a month without a rate: no amount, said so', () => {
    assert.deepEqual(costEntryCell(rows[2], 'USD'), { amount: null, converted: true, none: true, day: '', missing: 'XTS' })
    /* a USD row with no EUR rate: the missing one is EUR's */
    const [noEur] = costEntriesOf({ entries: [{ id: 'z', amount: 1, currency: 'USD', period: '2026-09', usd_micros: 1000000, eur_micros: null }] })
    assert.equal(costEntryCell(noEur, 'EUR').missing, 'EUR')
  })
  it('totals sum both currencies, none when a row has no rate', () => {
    assert.deepEqual(costEntryTotals(rows.slice(0, 2)), { usd: 82, eur: 73.8 })
    assert.deepEqual(costEntryTotals(rows), { usd: null, eur: null })
    assert.deepEqual(costEntryTotals([]), { usd: 0, eur: 0 })
  })
})

describe('cost entries: sort', () => {
  it('a header click cycles asc, desc, back to the newest month first', () => {
    let s = { col: '', dir: '' }
    s = cycleSort('usd', s, COST_ENTRY_COLUMNS)
    assert.deepEqual(s, { col: 'usd', dir: 'asc' })
    assert.deepEqual(cycleSort('usd', cycleSort('usd', s, COST_ENTRY_COLUMNS), COST_ENTRY_COLUMNS), { col: '', dir: '' })
    assert.equal(ids(sortCostEntries(rows, { col: '', dir: '' })), 'e,u,n')
  })
  it('by each column; a row with no rate sorts last either way', () => {
    assert.equal(ids(sortCostEntries(rows, { col: 'label', dir: 'asc' })), 'u,n,e')
    assert.equal(ids(sortCostEntries(rows, { col: 'usd', dir: 'asc' })), 'u,e,n')
    assert.equal(ids(sortCostEntries(rows, { col: 'usd', dir: 'desc' })), 'e,u,n')
    assert.equal(ids(sortCostEntries(rows, { col: 'eur', dir: 'desc' })), 'e,u,n')
    assert.equal(ids(sortCostEntries(rows, { col: 'period', dir: 'asc' })), 'n,e,u')
  })
})

describe('cost entries: filter row', () => {
  it('text in the label or note, every word', () => {
    assert.equal(ids(filterCostEntries(rows, { text: 'git' })), 'u')
    assert.equal(ids(filterCostEntries(rows, { text: 'no RATE' })), 'n')
    assert.equal(ids(filterCostEntries(rows, { text: 'invoice zzz' })), '')
  })
  it('month and entered currency', () => {
    assert.equal(ids(filterCostEntries(rows, { period: '2026-09' })), 'e,u')
    assert.equal(ids(filterCostEntries(rows, { period: '2026-09', currency: 'USD' })), 'u')
    assert.equal(ids(filterCostEntries(rows, COST_ENTRY_NO_FILTER)), 'e,u,n')
  })
  it('says when a filter is set, and offers the values the rows hold', () => {
    assert.equal(costEntriesFiltered(COST_ENTRY_NO_FILTER), false)
    assert.equal(costEntriesFiltered({ text: ' ' }), false)
    assert.equal(costEntriesFiltered({ currency: 'EUR' }), true)
    assert.deepEqual(costEntryFilterChoices(rows), { period: ['2026-09', '2026-07'], currency: ['EUR', 'USD', 'XTS'] })
  })
})

describe('cost entries: the mock prices as the hub', () => {
  it('USD, EUR and an unrated currency', () => {
    const mem = new Map([[TOKENS_MOCK_OPERATOR_KEY, '1'], [COST_ENTRIES_MOCK_KEY, JSON.stringify([
      { id: 'a', type: 'hr', amount: 10, currency: 'USD', period: '2026-09' },
      { id: 'b', type: 'hr', amount: 46, currency: 'EUR', period: '2026-09' },
      { id: 'c', type: 'hr', amount: 7, currency: 'XTS', period: '2026-09' },
    ])]])
    const store = { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, v), removeItem: (k) => mem.delete(k) }
    const [a, b, c] = mockCostEntryList('hr', store).entries
    assert.deepEqual([a.usd_micros, a.eur_micros], [10000000, Math.round(10000000 * MOCK_FX_RATES.EUR)])
    assert.deepEqual([b.usd_micros, b.eur_micros], [Math.round(46000000 / MOCK_FX_RATES.EUR), 46000000])
    assert.deepEqual([c.usd_micros, c.eur_micros], [null, null])
  })
})
