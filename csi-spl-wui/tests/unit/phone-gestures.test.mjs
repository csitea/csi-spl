// SPL-2148: the phone's two-finger swipe up opens the command palette (utils/phone-gestures.mjs).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { isPaletteSwipe, paletteSwipeStart } from '../../src/utils/phone-gestures.mjs'
import { isMobileBackSwipe, mobileSwipeStart } from '../../src/utils/mobile-stack.mjs'

const touch = (identifier, clientX, clientY) => ({ identifier, clientX, clientY })
const pt = (id, x, y) => ({ id, x, y })

describe('paletteSwipeStart', () => {
  it('takes exactly two fingers', () => {
    assert.deepEqual(paletteSwipeStart([touch(1, 150, 600), touch(2, 240, 600)]), [pt(1, 150, 600), pt(2, 240, 600)])
    assert.equal(paletteSwipeStart([touch(1, 150, 600)]), null)
    assert.equal(paletteSwipeStart([touch(1, 1, 1), touch(2, 2, 2), touch(3, 3, 3)]), null)
    assert.equal(paletteSwipeStart(null), null)
  })
})

describe('isPaletteSwipe', () => {
  const start = [pt(1, 150, 600), pt(2, 240, 600)]
  it('two fingers up 120 px side by side open it', () => {
    assert.equal(isPaletteSwipe(start, [pt(1, 155, 480), pt(2, 245, 480)]), true)
    assert.equal(isPaletteSwipe(start, [pt(2, 245, 480), pt(1, 155, 480)]), true, 'matched by finger id')
  })
  it('too short, sideways, or down: not ours', () => {
    assert.equal(isPaletteSwipe(start, [pt(1, 150, 560), pt(2, 240, 560)]), false)
    assert.equal(isPaletteSwipe(start, [pt(1, 250, 480), pt(2, 340, 480)]), false)
    assert.equal(isPaletteSwipe(start, [pt(1, 150, 720), pt(2, 240, 720)]), false)
  })
  it('one finger only up: not ours', () => {
    assert.equal(isPaletteSwipe(start, [pt(1, 150, 480), pt(2, 240, 600)]), false)
  })
  it('a pinch (fingers apart or together) is the browser zoom', () => {
    assert.equal(isPaletteSwipe(start, [pt(1, 110, 480), pt(2, 280, 480)]), false)
    assert.equal(isPaletteSwipe(start, [pt(1, 190, 480), pt(2, 200, 480)]), false)
  })
  it('a lost finger or no start: no', () => {
    assert.equal(isPaletteSwipe(start, [pt(1, 150, 480), pt(3, 240, 480)]), false)
    assert.equal(isPaletteSwipe(null, [pt(1, 150, 480), pt(2, 240, 480)]), false)
  })
})

describe('no clash with swipe-to-back', () => {
  it('a two-finger start is never a Back swipe start, a one-finger one never a palette start', () => {
    assert.equal(mobileSwipeStart(true, [touch(1, 20, 400), touch(2, 60, 400)]), null)
    assert.equal(paletteSwipeStart([touch(1, 20, 400)]), null)
  })
  it('the palette swipe is not a Back swipe, nor the Back swipe a palette swipe', () => {
    assert.equal(isMobileBackSwipe({ x0: 150, y0: 600, x1: 155, y1: 480, width: 390 }), false)
    assert.equal(isPaletteSwipe([pt(1, 20, 400), pt(2, 20, 460)], [pt(1, 200, 400), pt(2, 200, 460)]), false)
  })
})
