// Spec 143 expenses-cost-entries.md section 7 (SPL-4382; owner HUM-10, t1
// 4f48f878, msg b0ccc0aa): the insert per type on Expenses -> Cloud infra costs
// and HR costs. The form's checks against store.CheckCostEntry, the POST body of
// each type, the mock's round, and the client ops reaching the hub's paths.
//
// Run: node tests/unit/cost-entries.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  COST_ENTRIES_MOCK_KEY,
  COST_ENTRIES_MOCK_REFUSE_KEY,
  COST_ENTRY_TYPES,
  checkCostEntryForm,
  costEntriesOf,
  costEntryBody,
  emptyCostEntryForm,
  mockCostEntryCreate,
  mockCostEntryDelete,
  mockCostEntryList,
} from '../../src/utils/cost-entries.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const good = { label: 'Workspace invoice', amount: '64.80', currency: 'EUR', period: '2026-01', note: '' }
const CUR = ['USD', 'EUR']

function memStore(op = true) {
  const m = new Map(op ? [[TOKENS_MOCK_OPERATOR_KEY, '1']] : [])
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }
}

describe('the form checks what the hub checks', () => {
  it('a good form passes', () => assert.equal(checkCostEntryForm(good, CUR), ''))
  for (const [name, patch, want] of [
    ['no label', { label: '  ' }, 'err_label'],
    ['101 bytes', { label: 'x'.repeat(101) }, 'err_label'],
    ['51 two-byte letters count as the hub counts them', { label: 'я'.repeat(51) }, 'err_label'],
    ['no amount', { amount: '' }, 'err_amount'],
    ['amount 0', { amount: '0' }, 'err_amount'],
    ['a negative amount', { amount: '-1' }, 'err_amount'],
    ['1e10', { amount: '10000000000' }, 'err_amount'],
    ['a currency the hub does not quote', { currency: 'SEK' }, 'err_currency'],
    ['a lowercase currency', { currency: 'eur' }, 'err_currency'],
    ['no month', { period: '' }, 'err_period'],
    ['month 13', { period: '2026-13' }, 'err_period'],
    ['a day', { period: '2026-01-01' }, 'err_period'],
    ['2001 bytes of note', { note: 'x'.repeat(2001) }, 'err_note'],
  ]) it(name, () => assert.equal(checkCostEntryForm({ ...good, ...patch }, CUR), want))
  it('the empty form is this UTC month and is not sendable', () => {
    const f = emptyCostEntryForm(new Date('2026-11-07T10:00:00Z'))
    assert.equal(f.period, '2026-11')
    assert.equal(checkCostEntryForm(f, CUR), 'err_label')
  })
})

describe('the insert per type', () => {
  for (const type of COST_ENTRY_TYPES) {
    it(`${type}: the body carries the tab's type, the amount as a number, the label trimmed`, () => {
      assert.deepEqual(costEntryBody(type, { ...good, label: ' A ' }), { type, label: 'A', amount: 64.8, currency: 'EUR', period: '2026-01', note: '' })
    })
    it(`${type}: the mock stores it for this type only, delete removes it`, () => {
      const store = memStore()
      const made = mockCostEntryCreate(costEntryBody(type, good), store)
      assert.equal(mockCostEntryList(type, store).entries.length, 1)
      const other = COST_ENTRY_TYPES.find((x) => x !== type)
      assert.equal(mockCostEntryList(other, store).entries.length, 0)
      mockCostEntryDelete(made.id, store)
      assert.equal(mockCostEntryList(type, store).entries.length, 0)
    })
  }
  it('the types are the hub\'s, one tab each', () => {
    assert.deepEqual([...COST_ENTRY_TYPES], ['cloud', 'hr'])
    assert.match(read('../csi-spl-api/src/go/spool-hub-api/internal/store/cost_entries.go'), /CostEntryTypes = \[\]string\{"cloud", "hr"\}/)
  })
  it('the mock answers as the hub does: 403 to anyone else, 404 on an unknown id, one refusal when asked', () => {
    assert.throws(() => mockCostEntryList('cloud', memStore(false)), (e) => e.status === 403)
    assert.throws(() => mockCostEntryDelete('nope', memStore()), (e) => e.status === 404)
    const store = memStore()
    store.setItem(COST_ENTRIES_MOCK_REFUSE_KEY, 'no')
    assert.throws(() => mockCostEntryCreate(costEntryBody('hr', good), store), (e) => e.status === 400 && e.token === 'bad_cost_entry')
    assert.ok(mockCostEntryCreate(costEntryBody('hr', good), store).id, 'only once')
    assert.equal(JSON.parse(store.getItem(COST_ENTRIES_MOCK_KEY)).length, 1)
  })
})

describe('the list', () => {
  it('newest month first; no id is dropped; a bad body is empty', () => {
    const rows = costEntriesOf({ entries: [{ id: 'a', period: '2026-01', amount: 1 }, { id: 'b', period: '2026-03', amount: 2 }, { period: '2026-02' }] })
    assert.deepEqual(rows.map((r) => r.id), ['b', 'a'])
    assert.deepEqual(costEntriesOf(null), [])
  })
  it('an amount that is no number stays null, never 0', () => {
    assert.equal(costEntriesOf({ entries: [{ id: 'a', amount: 'x' }] })[0].amount, null)
  })
})

describe('the wiring', () => {
  it('the client ops reach the hub\'s paths, no new stub in the initial client', () => {
    const lazy = read('src/utils/spool-client-lazy.mjs')
    assert.match(lazy, /const entries = '\/v1\/operator\/cost-entries'/)
    assert.match(lazy, /op === 'entry_create'\) return live\(entries, json\('POST', a\)\)/)
    assert.match(lazy, /op === 'entry_delete'\) return live\(entries \+ '\/' \+ encodeURIComponent\(a\), \{ method: 'DELETE' \}\)/)
    assert.doesNotMatch(read('src/utils/spool-client.mjs'), /[cC]ostEntr/)
  })
  it('the page mounts the card with the open tab\'s type, keyed so a tab switch re-reads; Costs holds no form', () => {
    assert.match(read('src/pages/expenses/[[tab]].vue'), /<CostEntriesCard :key="entryType" :type="entryType" :readonly="!operator\.visible" \/>/)
    for (const p of ['spend', 'cloud', 'tokens', 'human', 'price']) assert.doesNotMatch(read(`src/pages/reporting/costs/${p}.vue`), /CostEntriesCard|entry_create/, p)
  })
})
