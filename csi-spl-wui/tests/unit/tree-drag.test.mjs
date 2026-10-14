// SPL-1873 (owner HUM-10, t1 1a9a14b6 msg 32d5ea87): the Qto file tree's
// re-order gesture and drop places (src/utils/tree-drag.mjs), without a
// browser: fake timers.
// Run: node tests/unit/tree-drag.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { TREE_DRAG_START_PX, createTreeDrag, dropWhere, siblingAt } from '../../src/utils/tree-drag.mjs'
import { LONG_PRESS_MS, LONG_PRESS_SLOP_PX } from '../../src/utils/touch-ui.mjs'

function rig() {
  const calls = []
  let pending = null
  const g = createTreeDrag({
    onHold: (x, y) => calls.push(['hold', x, y]),
    onStart: (x, y) => calls.push(['start', x, y]),
    onMove: (x, y) => calls.push(['move', x, y]),
    onDrop: (x, y) => calls.push(['drop', x, y]),
    onCancel: () => calls.push(['cancel']),
    setTimer: (fn, ms) => { pending = { fn, ms }; return 1 },
    clearTimer: () => { pending = null },
  })
  const fire = () => { const p = pending; pending = null; p?.fn() }
  return { g, calls, fire, get pending() { return pending } }
}
const mouse = (x, y, button = 0) => ({ pointerId: 1, pointerType: 'mouse', button, clientX: x, clientY: y })
const touch = (x, y) => ({ pointerId: 7, pointerType: 'touch', clientX: x, clientY: y })
const kinds = (r) => r.calls.map((c) => c[0])

describe('a mouse drags a row', () => {
  it('lifts after the start travel, moves, drops where it is released', () => {
    const r = rig()
    r.g.down(mouse(10, 100), true)
    r.g.move(mouse(10, 100 + TREE_DRAG_START_PX - 1))
    assert.deepEqual(r.calls, [], 'not yet: under the start travel')
    r.g.move(mouse(10, 130))
    r.g.move(mouse(10, 160))
    r.g.up(mouse(10, 160))
    assert.deepEqual(kinds(r), ['start', 'move', 'move', 'drop'])
    assert.deepEqual(r.calls.at(-1), ['drop', 10, 160])
    assert.equal(r.g.takeClick(), true, 'the release click does not also select')
  })
  it('Escape (cancel) while lifted drops nothing', () => {
    const r = rig()
    r.g.down(mouse(10, 100), true)
    r.g.move(mouse(10, 140))
    r.g.cancel()
    r.g.up(mouse(10, 140))
    assert.deepEqual(kinds(r), ['start', 'move', 'cancel'])
  })
  it('CONTROL: a click (no travel) is a click, and a row that may not drag never lifts', () => {
    const r = rig()
    r.g.down(mouse(10, 100), true)
    r.g.up(mouse(10, 100))
    assert.equal(r.g.takeClick(), false)
    r.g.down(mouse(10, 100), false)
    r.g.move(mouse(10, 200))
    r.g.up(mouse(10, 200))
    r.g.down(mouse(10, 100, 2), true)
    r.g.move(mouse(10, 200))
    assert.deepEqual(r.calls, [])
  })
})

describe('a finger: long press, then drag', () => {
  it('the hold opens the menu; a move after it lifts the row', () => {
    const r = rig()
    r.g.down(touch(50, 300), true)
    assert.equal(r.pending.ms, LONG_PRESS_MS)
    r.fire()
    assert.deepEqual(r.calls, [['hold', 50, 300]])
    assert.equal(r.g.holding, true, 'the page stops scrolling under the finger')
    r.g.move(touch(50, 300 + LONG_PRESS_SLOP_PX + 1))
    r.g.move(touch(50, 380))
    r.g.up(touch(50, 380))
    assert.deepEqual(kinds(r), ['hold', 'start', 'move', 'move', 'drop'])
  })
  it('a hold that lifts without moving keeps the menu: no drag', () => {
    const r = rig()
    r.g.down(touch(50, 300), true)
    r.fire()
    r.g.move(touch(52, 303))
    r.g.up(touch(52, 303))
    assert.deepEqual(kinds(r), ['hold'])
    assert.equal(r.g.takeClick(), true, 'the release click does not also select')
  })
  it('CONTROL: a swipe before the hold scrolls: no menu, no drag', () => {
    const r = rig()
    r.g.down(touch(50, 300), true)
    r.g.move(touch(50, 300 - LONG_PRESS_SLOP_PX - 1))
    assert.equal(r.pending, null, 'the hold timer is gone')
    r.g.move(touch(50, 100))
    r.g.up(touch(50, 100))
    assert.deepEqual(r.calls, [])
  })
  it('a row with a menu that may not drag: the hold opens the menu, a move after it ends the gesture', () => {
    const r = rig()
    r.g.down(touch(50, 300), false)
    r.fire()
    r.g.move(touch(50, 360))
    r.g.up(touch(50, 360))
    assert.deepEqual(kinds(r), ['hold'])
  })
})

describe('dropWhere - the gap or the folder', () => {
  const box = { top: 100, height: 40 }
  const all = { before: true, after: true, into: true }
  it('top band before, bottom band after, middle into', () => {
    assert.equal(dropWhere(102, box, all), 'before')
    assert.equal(dropWhere(120, box, all), 'into')
    assert.equal(dropWhere(138, box, all), 'after')
  })
  it('a row that takes no drop into it: the halves are before and after', () => {
    const gap = { before: true, after: true, into: false }
    assert.equal(dropWhere(119, box, gap), 'before')
    assert.equal(dropWhere(121, box, gap), 'after')
  })
  it('only into (a folder of another kind): anywhere on it', () => {
    assert.equal(dropWhere(101, box, { before: false, after: false, into: true }), 'into')
  })
  it('CONTROL: nothing taken, or no box, is null', () => {
    assert.equal(dropWhere(120, box, { before: false, after: false, into: false }), null)
    assert.equal(dropWhere(120, { top: 0, height: 0 }, all), null)
  })
})

describe('siblingAt - Alt+Up / Alt+Down within the folder', () => {
  /* / ; a ; f (open) ; f/x ; f/y ; b */
  const rows = [0, 1, 1, 2, 2, 1].map((depth) => ({ depth }))
  it('steps over an open folder\'s rows to the next sibling', () => {
    assert.equal(siblingAt(rows, 1, 1), 2)
    assert.equal(siblingAt(rows, 2, 1), 5)
    assert.equal(siblingAt(rows, 5, -1), 2)
  })
  it('stops at the end of its folder', () => {
    assert.equal(siblingAt(rows, 3, -1), -1)
    assert.equal(siblingAt(rows, 4, 1), -1)
    assert.equal(siblingAt(rows, 1, -1), -1)
    assert.equal(siblingAt(rows, 5, 1), -1)
  })
})
