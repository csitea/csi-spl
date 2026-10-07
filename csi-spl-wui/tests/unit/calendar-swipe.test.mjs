// spec 106 T002: the phone calendar's gesture classifier - swipe left =
// next, right from mid-screen = prev, right from x <= 24 = back, diagonal
// drift = none; the 10 / 16 px directional lock and the 8 px / 300 ms tap of
// S2-2; rtl mirrored. Each block carries a control: the nearest track that
// must come out differently.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  CAL_SWIPE_EDGE_PX, calSwipeClaims, calSwipeClassify, calSwipeInEdge, calSwipeIsHold, calSwipeIsTap,
  calSwipeLock, calSwipeTrackLock,
} from '../../src/utils/calendar-swipe.mjs'

const W = 390
/** a straight track from (x0, y0) by (dx, dy) in `n` steps */
const line = (x0, y0, dx, dy, n = 10, ms = 20) =>
  Array.from({ length: n + 1 }, (_, i) => ({ x: x0 + (dx * i) / n, y: y0 + (dy * i) / n, t: i * ms }))

describe('page turns', () => {
  it('left = next, right from mid-screen = prev', () => {
    assert.equal(calSwipeClassify({ points: line(300, 400, -120, 4), width: W }), 'next')
    assert.equal(calSwipeClassify({ points: line(100, 400, 120, 4), width: W }), 'prev')
  })
  it('right from x <= 24 = back; control: from x = 25 it is prev', () => {
    assert.equal(CAL_SWIPE_EDGE_PX, 24)
    assert.equal(calSwipeClassify({ points: line(24, 400, 150, 2), width: W }), 'back')
    assert.equal(calSwipeClassify({ points: line(5, 400, 150, 2), width: W }), 'back')
    assert.equal(calSwipeClassify({ points: line(25, 400, 150, 2), width: W }), 'prev')
  })
  it('a left swipe from the edge is still next (the edge only matters for Back)', () => {
    assert.equal(calSwipeClassify({ points: line(20, 400, -100, 0), width: W }), 'next')
  })
  it('too short is none; control: the same direction past 64 px turns', () => {
    assert.equal(calSwipeClassify({ points: line(200, 400, -40, 0), width: W }), 'none')
    assert.equal(calSwipeClassify({ points: line(200, 400, -64, 0), width: W }), 'next')
  })
  it('rtl mirrors: right = next, left from mid = prev, left from the right edge = back', () => {
    assert.equal(calSwipeClassify({ points: line(100, 400, 120, 0), width: W, rtl: true }), 'next')
    assert.equal(calSwipeClassify({ points: line(300, 400, -120, 0), width: W, rtl: true }), 'prev')
    assert.equal(calSwipeClassify({ points: line(W - 10, 400, -150, 0), width: W, rtl: true }), 'back')
    assert.equal(calSwipeClassify({ points: line(10, 400, 150, 0), width: W, rtl: true }), 'next', 'control: the left edge is not Back in rtl')
  })
  it('junk is none', () => {
    assert.equal(calSwipeClassify({ points: [{ x: 1, y: 1 }], width: W }), 'none')
    assert.equal(calSwipeClassify({ points: line(300, 400, -120, 0), width: 0 }), 'none')
    assert.equal(calSwipeClassify(/** @type {any} */ (null)), 'none')
  })
})

describe('directional lock (S2-2)', () => {
  it('diagonal drift is none: dy reaches 10 before dx reaches 16', () => {
    /* a thumb flick down the Day grid that drifts 100 px sideways */
    assert.equal(calSwipeClassify({ points: line(300, 200, -100, 300), width: W }), 'none')
    /* 45 degrees: dy hits 10 at dx 10, before 16 */
    assert.equal(calSwipeClassify({ points: line(300, 200, -150, 150), width: W }), 'none')
  })
  it('the order decides: vertical first stays vertical even when it ends sideways', () => {
    const vFirst = [{ x: 300, y: 200, t: 0 }, { x: 300, y: 212, t: 20 }, { x: 150, y: 214, t: 60 }]
    assert.equal(calSwipeTrackLock(vFirst), 'y')
    assert.equal(calSwipeClassify({ points: vFirst, width: W }), 'none')
    /* control: the same end point reached sideways first turns the page */
    const hFirst = [{ x: 300, y: 200, t: 0 }, { x: 280, y: 202, t: 20 }, { x: 150, y: 214, t: 60 }]
    assert.equal(calSwipeTrackLock(hFirst), 'x')
    assert.equal(calSwipeClassify({ points: hFirst, width: W }), 'next')
  })
  it('a lock holds once set', () => {
    assert.equal(calSwipeLock({ x: 0, y: 0 }, { x: 5, y: 9 }), 'none')
    assert.equal(calSwipeLock({ x: 0, y: 0 }, { x: 5, y: 10 }), 'y')
    assert.equal(calSwipeLock({ x: 0, y: 0 }, { x: 16, y: 9 }), 'x')
    assert.equal(calSwipeLock({ x: 0, y: 0 }, { x: 15, y: 0 }), 'none')
    assert.equal(calSwipeLock({ x: 0, y: 0 }, { x: 200, y: 0 }, 'y'), 'y')
  })
})

describe('the swipe claim (9.4 #1)', () => {
  it('claims everywhere but the 24 px Back edge (rtl: the right edge)', () => {
    assert.equal(calSwipeClaims(100, W), true)
    assert.equal(calSwipeClaims(24, W), false)
    assert.equal(calSwipeClaims(25, W), true)
    assert.equal(calSwipeClaims(W - 10, W, true), false)
    assert.equal(calSwipeClaims(10, W, true), true)
    assert.equal(calSwipeInEdge(0, W), true)
  })
})

describe('tap and hold (S2-2)', () => {
  it('a tap is < 8 px and < 300 ms', () => {
    assert.equal(calSwipeIsTap(line(100, 100, 3, 3, 3, 50)), true)
    /* controls: 8 px of travel, or 300 ms down, is no tap */
    assert.equal(calSwipeIsTap(line(100, 100, 8, 0, 4, 20)), false)
    assert.equal(calSwipeIsTap(line(100, 100, 0, 0, 3, 100)), false)
    /* a scroll that came back to where it started is no tap */
    assert.equal(calSwipeIsTap([{ x: 0, y: 0, t: 0 }, { x: 0, y: 30, t: 50 }, { x: 0, y: 0, t: 100 }]), false)
    assert.equal(calSwipeIsTap([]), false)
  })
  it('a still finger held > 400 ms is a hold; control: 400 ms or moving is not', () => {
    const still = [{ x: 50, y: 50, t: 1000 }, { x: 52, y: 51, t: 1200 }]
    assert.equal(calSwipeIsHold(still, 1401), true)
    assert.equal(calSwipeIsHold(still, 1400), false)
    assert.equal(calSwipeIsHold([...still, { x: 70, y: 50, t: 1300 }], 1500), false)
  })
})
