// SPL-2062 (owner HUM-10, t1 508e17a0): the phone section strip shows whole
// controls only. stripFit picks how many share its width: as many as fit at
// STRIP_ITEM_MIN, never more than there are, at least one. Each is then
// view / fit wide, so at 360, 390 and 412 px no control is cut and each
// stays >= 44 px. The browser half is tests/e2e/mobile-rail-whole-icons.
//
// Run: node tests/unit/strip-fit.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { STRIP_ITEM_MIN, loopPosition, onStripGrid, stripFit } from '../../src/utils/section-strip.mjs'

describe('stripFit', () => {
  it('fits as many 64 px controls as the phone is wide, and each stays a 44 px target', () => {
    assert.equal(STRIP_ITEM_MIN, 64)
    for (const [view, fit] of [[360, 5], [390, 6], [412, 6], [320, 5], [768, 12]]) {
      assert.equal(stripFit(view, 14), fit, String(view))
      assert.ok(view / fit >= 44, String(view))
      assert.ok(view / fit >= STRIP_ITEM_MIN, String(view))
    }
  })
  it('never more than there are: a short row shares the whole width', () => {
    assert.equal(stripFit(390, 4), 4)
    assert.equal(stripFit(390, 1), 1)
  })
  it('at least one, whatever it is given', () => {
    assert.equal(stripFit(40, 14), 1)
    assert.equal(stripFit(0, 14), 1)
    assert.equal(stripFit(390, 0), 1)
    assert.equal(stripFit(Number.NaN, 5), 1)
  })
})

describe('onStripGrid', () => {
  it('puts a centring write on a control edge, so the snap does not move it again', () => {
    assert.equal(onStripGrid(715 + 32.5, 65), 780)
    assert.equal(onStripGrid(715 + 30, 65), 715)
    assert.equal(onStripGrid(-100, 65), -130)
    assert.equal(onStripGrid(123.4, 0), 123.4)
  })
})

describe('loopPosition at a snapping rest', () => {
  it('a strip resting on set / 2 (an even count of controls) does not jump a copy over', () => {
    const set = 14 * (820 / 12)
    assert.equal(loopPosition(Math.floor(set / 2), set), Math.floor(set / 2))
    assert.equal(loopPosition(Math.ceil(set * 1.5), set), Math.ceil(set * 1.5))
    assert.equal(loopPosition(set / 2 - 5, set), set / 2 - 5 + set)
  })
})
