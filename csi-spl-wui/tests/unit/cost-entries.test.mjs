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
  mockCostEntryLabels,
  MOCK_COST_LABEL_MASTER,
  checkCostLabelRows,
  costEntriesMasterOf,
  costLabelRows,
  costLabelsBody,
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
    ['101 characters', { label: 'x'.repeat(101) }, 'err_label'],
    ['101 Cyrillic characters', { label: 'я'.repeat(101) }, 'err_label'],
    ['no amount', { amount: '' }, 'err_amount'],
    ['amount 0', { amount: '0' }, 'err_amount'],
    ['a negative amount', { amount: '-1' }, 'err_amount'],
    ['1e10', { amount: '10000000000' }, 'err_amount'],
    ['a currency the hub does not quote', { currency: 'SEK' }, 'err_currency'],
    ['a lowercase currency', { currency: 'eur' }, 'err_currency'],
    ['no month', { period: '' }, 'err_period'],
    ['month 13', { period: '2026-13' }, 'err_period'],
    ['a day', { period: '2026-01-01' }, 'err_period'],
    ['2001 characters of note', { note: 'x'.repeat(2001) }, 'err_note'],
    ['2001 Cyrillic characters of note', { note: 'я'.repeat(2001) }, 'err_note'],
    ['201 Cyrillic characters of source', { source: 'я'.repeat(201) }, 'err_source'],
    ['21 Cyrillic characters of account', { account: 'я'.repeat(21) }, 'err_source'],
    /* SPL-5668: the form counts what costEntryBody sends, the trimmed value */
    ['201 characters of source', { source: 'x'.repeat(201) }, 'err_source'],
    ['21 characters of account', { account: 'x'.repeat(21) }, 'err_source'],
    ['201 characters of source plus trailing spaces', { source: 'x'.repeat(201) + '   ' }, 'err_source'],
  ]) it(name, () => assert.equal(checkCostEntryForm({ ...good, ...patch }, CUR), want))
  /* SPL-5639: the hub counts characters (utf8.RuneCountInString), so the form does too */
  for (const [name, patch] of [
    ['100 Cyrillic characters of label', { label: 'я'.repeat(100) }],
    ['2000 Cyrillic characters of note', { note: 'я'.repeat(2000) }],
    ['200 Cyrillic characters of source', { source: 'я'.repeat(200) }],
    ['20 Cyrillic characters of account', { account: 'я'.repeat(20) }],
    /* SPL-5668: the hub gets the trimmed source and account (costEntryBody) */
    ['200 characters of source plus trailing spaces', { source: 'x'.repeat(200) + '   ' }],
    ['20 characters of account plus trailing spaces', { account: 'x'.repeat(20) + '  ' }],
    ['200 Cyrillic characters of source padded with spaces', { source: '  ' + 'я'.repeat(200) + '  ' }],
    ['20 Cyrillic characters of account padded with spaces', { account: ' ' + 'я'.repeat(20) + ' ' }],
    ['100 astral characters of label (one code point, two UTF-16 units each)', { label: '😀'.repeat(100) }],
  ]) it(name + ' pass', () => assert.equal(checkCostEntryForm({ ...good, ...patch }, CUR), ''))
  it('the empty form is this UTC month and is not sendable', () => {
    const f = emptyCostEntryForm(new Date('2026-11-07T10:00:00Z'))
    assert.equal(f.period, '2026-11')
    assert.equal(checkCostEntryForm(f, CUR), 'err_label')
  })
})

/* SPL-5693: the form trims what the hub's strings.TrimSpace trims, and counts source/account on hr only */
describe('the form trims as the hub does, source and account on hr only', () => {
  it('a NEL-only label is no label', () => assert.equal(checkCostEntryForm({ ...good, label: '\u0085' }, CUR), 'err_label'))
  it('a label padded with NEL counts trimmed', () => {
    const f = { ...good, label: '\u0085' + 'x'.repeat(100) + '\u0085' }
    assert.equal(checkCostEntryForm(f, CUR), '')
    assert.equal(costEntryBody('cloud', f).label, 'x'.repeat(100))
  })
  it('a BOM-only label is a label, as the hub keeps U+FEFF', () => assert.equal(checkCostEntryForm({ ...good, label: '\ufeff' }, CUR), ''))
  it('the hr body trims NEL off source and account', () => {
    const body = costEntryBody('hr', { ...good, source: '\u0085payslip\u0085', account: '\u00a0acct\u3000' })
    assert.equal(body.source, 'payslip')
    assert.equal(body.account, 'acct')
  })
  it('a cloud entry with 201 characters of source passes', () => assert.equal(checkCostEntryForm({ ...good, source: 'x'.repeat(201) }, CUR, 'cloud'), ''))
  it('a cloud entry with 21 characters of account passes', () => assert.equal(checkCostEntryForm({ ...good, account: 'x'.repeat(21) }, CUR, 'cloud'), ''))
  it('an hr entry with 201 characters of source is refused', () => assert.equal(checkCostEntryForm({ ...good, source: 'x'.repeat(201) }, CUR, 'hr'), 'err_source'))
  it('the card passes its tab type', () => assert.match(read('src/components/expenses/CostEntriesCard.vue'), /checkCostEntryForm\(f, currencies\.value, props\.type\)/))
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

// SPL-5546 (rdb 0285): the labels per locale, the master's the entry's own text
describe('the labels in other languages', () => {
  const LOCS = ['bg', 'en', 'fi']
  it('the list carries each entry\'s labels and the master locale; a bad label map is dropped', () => {
    const body = { master_locale: 'bg', entries: [{ id: 'a', label: 'Заплата', labels: { bg: 'Заплата', en: 'Salary', 'x-y': 'no', fi: 3 } }] }
    assert.equal(costEntriesMasterOf(body), 'bg')
    assert.equal(costEntriesMasterOf({ master_locale: 'bulgarian' }), '')
    const [e] = costEntriesOf(body)
    assert.deepEqual(e.labels, { bg: 'Заплата', en: 'Salary' })
    assert.deepEqual(costLabelRows(e, 'bg'), [{ locale: 'en', text: 'Salary' }], 'the master\'s row is not an editor row')
  })
  for (const [name, rows, want] of [
    ['two languages', [{ locale: 'en', text: 'Salary' }, { locale: 'fi', text: 'Palkka' }], ''],
    ['none (all removed)', [], ''],
    ['the master language', [{ locale: 'bg', text: 'x' }], 'err_labels_locale'],
    ['a language twice', [{ locale: 'en', text: 'a' }, { locale: 'en', text: 'b' }], 'err_labels_locale'],
    ['an unknown language', [{ locale: 'xx', text: 'a' }], 'err_labels_locale'],
    ['an empty label', [{ locale: 'en', text: '  ' }], 'err_label'],
    ['101 characters', [{ locale: 'en', text: 'я'.repeat(101) }], 'err_label'],
  ]) it(`label rows: ${name}`, () => assert.equal(checkCostLabelRows(rows, 'bg', LOCS), want))
  it('the PATCH body trims each label; the mock keeps the master\'s text and refuses a change to it', () => {
    assert.deepEqual(costLabelsBody([{ locale: 'en', text: ' Salary ' }]), { labels: { en: 'Salary' } })
    const store = memStore()
    const e = mockCostEntryCreate(costEntryBody('hr', good), store)
    assert.deepEqual(mockCostEntryLabels(e.id, { labels: { fi: 'Lasku' } }, store).labels, { fi: 'Lasku', [MOCK_COST_LABEL_MASTER]: good.label })
    assert.deepEqual(mockCostEntryList('hr', store).entries[0].labels, { fi: 'Lasku', [MOCK_COST_LABEL_MASTER]: good.label })
    assert.throws(() => mockCostEntryLabels(e.id, { labels: { [MOCK_COST_LABEL_MASTER]: 'Other' } }, store), (x) => x.status === 400)
    assert.throws(() => mockCostEntryLabels('nope', { labels: {} }, store), (x) => x.status === 404)
  })
  it('the client op reaches PATCH .../{id}/labels; the components ask in the locale', () => {
    const lazy = read('src/utils/spool-client-lazy.mjs')
    assert.match(lazy, /op === 'entry_labels'\) return live\(entries \+ '\/' \+ encodeURIComponent\(a\) \+ '\/labels', json\('PATCH', b\)\)/)
    assert.match(lazy, /'\/v1\/operator\/hr-components' \+ \(\/\^\[a-z\]\{2\}\$\/\.test/)
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
    assert.match(read('src/pages/expenses/[[tab]].vue'), /<CostEntriesCard :key="entryType" :type="entryType" :readonly="!operator\.visible && !writer" :admin="operator\.visible" \/>/)
    for (const p of ['spend', 'cloud', 'tokens', 'human', 'price']) assert.doesNotMatch(read(`src/pages/reporting/costs/${p}.vue`), /CostEntriesCard|entry_create/, p)
  })
})
