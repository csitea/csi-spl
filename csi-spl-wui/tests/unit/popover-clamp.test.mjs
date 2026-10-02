// components/DeadlinePicker.vue place(): SPL-1147, the pop-up is always fully
// inside the viewport.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { clampPopover } from '../../src/utils/popover-clamp.mjs'

const box = (left, top, width = 160, height = 30) => ({ left, top, right: left + width, bottom: top + height })
const VP = { w: 200, h: 300, vw: 1000, vh: 800 }

describe('clampPopover', () => {
  it('opens under the field, left edges aligned, 4 px below', () => {
    assert.deepEqual(clampPopover({ ...VP, anchor: box(100, 100) }), { left: 100, top: 134 })
  })

  it('flips left near the right edge: right edges aligned', () => {
    const a = box(900, 100, 60)
    assert.deepEqual(clampPopover({ ...VP, anchor: a }), { left: a.right - 200, top: 134 })
  })

  it('flips up near the bottom when it fits above', () => {
    const a = box(100, 600)
    assert.deepEqual(clampPopover({ ...VP, anchor: a }), { left: 100, top: 600 - 4 - 300 })
  })

  it('stays below when it does not fit above either, clamped inside the bottom edge', () => {
    const r = clampPopover({ ...VP, vh: 400, anchor: box(100, 200) })
    assert.equal(r.top, 400 - 300 - 8)
  })

  it('clamps 8 px inside the left and top edges', () => {
    assert.deepEqual(clampPopover({ ...VP, vw: 150, anchor: box(-50, -100) }), { left: 8, top: 8 })
  })

  it('edge and gap are parameters', () => {
    assert.deepEqual(clampPopover({ ...VP, anchor: box(0, 100), edge: 20, gap: 10 }), { left: 20, top: 140 })
  })
})
