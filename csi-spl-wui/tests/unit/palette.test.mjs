// 081 AC3: the command palette ranks prefix, word prefix, substring, then
// recency; `>` switches to actions; recents keep the last 20 uses.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { memoryStore } from '../../src/utils/prefs.mjs'
import {
  PALETTE_RECENT_KEY, PALETTE_RECENT_MAX, TIER_EXACT, TIER_PREFIX, TIER_WORD, TIER_SUBSTRING,
  parseQuery, matchTier, rankItems, loadRecent, pushRecent,
} from '../../src/utils/palette.mjs'

const item = (id, label = id, keywords) => (keywords ? { id, label, keywords } : { id, label })
const ids = (rows) => rows.map((r) => r.id)

describe('rankItems (AC3)', () => {
  const items = [item('feedback'), item('fee-review'), item('coffee')]

  it('fee: feedback, fee-review, coffee', () => {
    assert.deepEqual(ids(rankItems(items, 'fee', [])), ['feedback', 'fee-review', 'coffee'])
  })
  it('a recent item outranks an equal match', () => {
    assert.deepEqual(ids(rankItems(items, 'fee', ['fee-review'])), ['fee-review', 'feedback', 'coffee'])
  })
  it('recency never lifts an item over a better tier', () => {
    assert.deepEqual(ids(rankItems(items, 'fee', ['coffee'])), ['feedback', 'fee-review', 'coffee'])
  })
  it('exact, prefix, word prefix, substring, in that order', () => {
    const rows = [item('sub', 'pre-review'), item('word', 'the review'), item('pre', 'reviews'), item('eq', 'Review')]
    assert.deepEqual(ids(rankItems(rows, 'review', [])), ['eq', 'pre', 'sub', 'word'])
    assert.deepEqual(ids(rankItems(rows, 'view', [])), ['sub', 'word', 'pre', 'eq'])
  })
  it('case-insensitive; the query is trimmed; no match is dropped', () => {
    assert.deepEqual(ids(rankItems(items, '  FEED ', [])), ['feedback'])
    assert.deepEqual(ids(rankItems(items, 'zzz', [])), [])
  })
  it('a keyword matches like the label, best tier wins', () => {
    const rows = [item('/dm/HUM-3', 'FirstName LastName', ['HUM-3']), item('hum', 'humans')]
    assert.deepEqual(ids(rankItems(rows, 'hum-3', [])), ['/dm/HUM-3'])
    assert.equal(matchTier(rows[0], 'last'), TIER_WORD)
    assert.equal(matchTier(rows[0], 'hum'), TIER_PREFIX)
  })
  it('empty query: the recents present in items, newest first', () => {
    assert.deepEqual(ids(rankItems(items, '', ['gone', 'coffee', 'feedback'])), ['coffee', 'feedback'])
    assert.deepEqual(ids(rankItems(items, '   ', null)), [])
  })
  it('bad input is no rows, not a throw', () => {
    assert.deepEqual(rankItems(null, 'x', null), [])
    assert.deepEqual(ids(rankItems([null, { label: 'x' }, item('x')], 'x', 'nope')), ['x'])
  })
})

describe('matchTier', () => {
  it('names each tier and -1 for none or an empty query', () => {
    assert.equal(matchTier(item('a', 'Feedback'), 'feedback'), TIER_EXACT)
    assert.equal(matchTier(item('a', 'feedback'), 'feed'), TIER_PREFIX)
    assert.equal(matchTier(item('a', '#ops-feedback'), 'feed'), TIER_WORD)
    assert.equal(matchTier(item('a', 'coffee'), 'fee'), TIER_SUBSTRING)
    assert.equal(matchTier(item('a', 'coffee'), 'tea'), -1)
    assert.equal(matchTier(item('a', 'coffee'), ''), -1)
  })
})

describe('parseQuery', () => {
  it('a leading > is actions, the rest navigates', () => {
    assert.deepEqual(parseQuery('>arch'), { mode: 'actions', text: 'arch' })
    assert.deepEqual(parseQuery('  > arch '), { mode: 'actions', text: 'arch' })
    assert.deepEqual(parseQuery('>'), { mode: 'actions', text: '' })
    assert.deepEqual(parseQuery(' fee '), { mode: 'go', text: 'fee' })
    assert.deepEqual(parseQuery('a>b'), { mode: 'go', text: 'a>b' })
    assert.deepEqual(parseQuery(undefined), { mode: 'go', text: '' })
  })
})

describe('pushRecent / loadRecent', () => {
  it('newest first, no duplicates, under spool.palette-recent', () => {
    const store = memoryStore()
    pushRecent(store, 'a')
    pushRecent(store, 'b')
    assert.deepEqual(pushRecent(store, 'a'), ['a', 'b'])
    assert.equal(PALETTE_RECENT_KEY, 'spool.palette-recent')
    assert.deepEqual(JSON.parse(store._data[PALETTE_RECENT_KEY]), ['a', 'b'])
    assert.deepEqual(loadRecent(store), ['a', 'b'])
  })
  it('keeps the last 20', () => {
    const store = memoryStore()
    for (let i = 0; i < 25; i++) pushRecent(store, `id-${i}`)
    const got = loadRecent(store)
    assert.equal(PALETTE_RECENT_MAX, 20)
    assert.equal(got.length, 20)
    assert.equal(got[0], 'id-24')
    assert.equal(got[19], 'id-5')
  })
  it('an empty id changes nothing; junk in storage reads as clean', () => {
    const store = memoryStore({ [PALETTE_RECENT_KEY]: '["a", 3, "", "a", null, "b"]' })
    assert.deepEqual(loadRecent(store), ['a', 'b'])
    assert.deepEqual(pushRecent(store, ''), ['a', 'b'])
    assert.deepEqual(loadRecent(memoryStore({ [PALETTE_RECENT_KEY]: '{oops' })), [])
    assert.deepEqual(loadRecent(memoryStore({ [PALETTE_RECENT_KEY]: '{"a":1}' })), [])
  })
})
