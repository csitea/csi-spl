// SPL-2146: the channel feed draws only the rows near the viewport; this
// module adds up which rows that is (src/utils/feed-virtual.mjs).
// Run: node tests/unit/feed-virtual.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { EST_ROW_PX, VIRTUAL_MIN, estimateOf, feedRange, offsetOf, rowSizes, slotHeights } from '../../src/utils/feed-virtual.mjs'

const even = (n, px = 100) => Array.from({ length: n }, () => px)

describe('feedRange', () => {
  it('draws the viewport plus the overscan, the spacers hold the rest', () => {
    const r = feedRange({ sizes: even(2000), viewTop: 50000, viewBottom: 50800, overscan: 1000 })
    assert.equal(r.start, 490)
    assert.equal(r.end, 518)
    assert.equal(r.top, 49000)
    assert.equal(r.bottom, (2000 - 518) * 100)
    assert.equal(r.top + offsetOf(even(2000), r.end) - offsetOf(even(2000), r.start) + r.bottom, 200000)
  })
  it('at the top draws from row 0 with no top spacer', () => {
    const r = feedRange({ sizes: even(2000), viewTop: 0, viewBottom: 800, overscan: 1200 })
    assert.deepEqual([r.start, r.top], [0, 0])
    assert.equal(r.end, 20)
  })
  it('past the end still draws the last row', () => {
    const r = feedRange({ sizes: even(500), viewTop: 99999, viewBottom: 100799, overscan: 0 })
    assert.equal(r.start, 499)
    assert.equal(r.end, 500)
    assert.equal(r.bottom, 0)
  })
  it('an empty list draws nothing', () => {
    assert.deepEqual(feedRange({ sizes: [] }), { start: 0, end: 0, top: 0, bottom: 0 })
  })
  it('a 2000-row channel draws far fewer rows than it holds', () => {
    const r = feedRange({ sizes: even(2000, 140), viewTop: 0, viewBottom: 800 })
    assert.ok(r.end - r.start < VIRTUAL_MIN, `${r.end - r.start} rows`)
  })
})

describe('rowSizes / estimateOf', () => {
  it('a measured row keeps its height, the others take the estimate given', () => {
    assert.deepEqual(rowSizes(['a', 'b', 'c'], new Map([['a', 100], ['c', 200]]), 150), [100, 150, 200])
  })
  it('with no estimate given a row not measured is EST_ROW_PX', () => {
    assert.deepEqual(rowSizes(['a', 'b'], new Map()), [EST_ROW_PX, EST_ROW_PX])
  })
  it('the estimate is the mean of the measured rows, else EST_ROW_PX', () => {
    assert.equal(estimateOf(new Map([['a', 100], ['b', 200]])), 150)
    assert.equal(estimateOf(new Map()), EST_ROW_PX)
  })
})

describe('slotHeights', () => {
  it('a slot is the distance to the next row, the last one takes the same gap', () => {
    assert.deepEqual(slotHeights([0, 110, 260], [100, 140, 90]), [110, 150, 100])
  })
  it('no rows, no slots', () => {
    assert.deepEqual(slotHeights([], []), [])
  })
})
