// Gmail-style selection on the issues list (owner HUM-10, t1 53ab04e7, msg
// 14b0e604): the selection state and the bounded per-issue runner.
//
// Run: node tests/unit/issues-bulk.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { importTs } from './lib/load-ts.mjs'

const { BULK_PARALLEL, keepShown, pageState, rangeSelect, runBulk, toggleAll, toggleKey } = await importTs('src/utils/issues-bulk.ts')

const ROWS = ['SPL-9', 'SPL-8', 'SPL-7', 'SPL-6', 'SPL-5']

describe('toggleKey', () => {
  it('checks, then unchecks, keeping the order checked', () => {
    let s = toggleKey([], 'SPL-7')
    s = toggleKey(s, 'SPL-9')
    assert.deepEqual(s, ['SPL-7', 'SPL-9'])
    assert.deepEqual(toggleKey(s, 'SPL-7'), ['SPL-9'])
  })
  it('an explicit state is idempotent and returns the same list', () => {
    const s = ['SPL-7']
    assert.equal(toggleKey(s, 'SPL-7', true), s)
    assert.equal(toggleKey(s, 'SPL-8', false), s)
    assert.deepEqual(toggleKey(s, 'SPL-7', false), [])
  })
  it('an empty key changes nothing', () => {
    assert.deepEqual(toggleKey(['SPL-7'], ''), ['SPL-7'])
  })
})

describe('rangeSelect (shift-click)', () => {
  it('checks every row between the anchor and the click, either direction', () => {
    assert.deepEqual(rangeSelect(['SPL-8'], ROWS, 'SPL-8', 'SPL-6', true), ['SPL-8', 'SPL-7', 'SPL-6'])
    assert.deepEqual(rangeSelect([], ROWS, 'SPL-5', 'SPL-7', true).sort(), ['SPL-5', 'SPL-6', 'SPL-7'])
  })
  it('unchecks the run when the click unchecks', () => {
    assert.deepEqual(rangeSelect(ROWS, ROWS, 'SPL-9', 'SPL-7', false), ['SPL-6', 'SPL-5'])
  })
  it('no anchor (or one gone from the list) is a plain click', () => {
    assert.deepEqual(rangeSelect([], ROWS, '', 'SPL-6', true), ['SPL-6'])
    assert.deepEqual(rangeSelect([], ROWS, 'SPL-1', 'SPL-6', true), ['SPL-6'])
  })
})

describe('pageState / toggleAll (the header box)', () => {
  it('reads none, some, all for the rows shown', () => {
    assert.equal(pageState([], ROWS), 'none')
    assert.equal(pageState(['SPL-7'], ROWS), 'some')
    assert.equal(pageState([...ROWS], ROWS), 'all')
    assert.equal(pageState(['SPL-1'], ROWS), 'none')
  })
  it('checks every shown row, then a second click clears them', () => {
    const all = toggleAll(['SPL-7'], ROWS)
    assert.equal(all.length, ROWS.length)
    assert.equal(pageState(all, ROWS), 'all')
    assert.deepEqual(toggleAll(all, ROWS), [])
  })
  it('a second click keeps a checked row that is not shown', () => {
    assert.deepEqual(toggleAll(['SPL-1', ...ROWS], ROWS), ['SPL-1'])
  })
  it('CONTROL: an empty list is never "all"', () => {
    assert.equal(pageState([], []), 'none')
  })
})

describe('keepShown', () => {
  it('drops the keys no longer listed, same list when nothing went', () => {
    const s = ['SPL-9', 'SPL-1']
    assert.deepEqual(keepShown(s, ROWS), ['SPL-9'])
    const t = ['SPL-9']
    assert.equal(keepShown(t, ROWS), t)
  })
})

describe('runBulk', () => {
  it('runs every key, at most BULK_PARALLEL at once, and names the failures', async () => {
    const keys = Array.from({ length: 11 }, (_, i) => `SPL-${i + 1}`)
    let live = 0
    let peak = 0
    const ticks = []
    const out = await runBulk(keys, async (k) => {
      live++
      peak = Math.max(peak, live)
      await new Promise((r) => setTimeout(r, 5))
      live--
      if (k === 'SPL-3' || k === 'SPL-10') throw Object.assign(new Error('nope'), { status: 403 })
    }, { onProgress: (n, total) => ticks.push(`${n}/${total}`) })
    assert.equal(BULK_PARALLEL, 4)
    assert.equal(peak, BULK_PARALLEL)
    assert.deepEqual(out.failed.map((f) => f.key), ['SPL-3', 'SPL-10'])
    assert.equal(out.failed[0].error.status, 403)
    assert.equal(out.done.length, 9)
    assert.equal(ticks.length, 11)
    assert.equal(ticks.at(-1), '11/11')
  })
  it('an empty list does no call', async () => {
    let calls = 0
    const out = await runBulk([], async () => { calls++ })
    assert.deepEqual(out, { done: [], failed: [] })
    assert.equal(calls, 0)
  })
})
