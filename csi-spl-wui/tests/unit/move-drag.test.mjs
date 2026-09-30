// SPL-1134 (specs/045 §3.9): the drag handle's gesture and the one-row hit
// rule, without a browser (fake timers, fake elements).
// Run: node tests/unit/move-drag.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  MOVE_DRAG_START_PX,
  MOVE_HANDLE_PX,
  MOVE_TOUCH_HOLD_MS,
  createHandleDrag,
  moveHit,
  sameHit,
} from '../../src/utils/move-drag.mjs'

/** A fake element: `closest` answers the row it sits in. */
const inRow = (dataset) => ({ closest: (sel) => (sel === '[data-move-drop]' && dataset ? { dataset } : null) })
const topic = { kind: 'topic' }
const reply = { kind: 'message' }

describe('moveHit - the ONE row under the pointer', () => {
  it('a topic drag hits a channel row, with the row\'s verdict', () => {
    assert.deepEqual(moveHit(inRow({ moveDrop: 'channel', moveId: 'ops', moveOk: 'true' }), topic), { kind: 'channel', id: 'ops', scope: '', ok: true, title: '' })
    assert.deepEqual(moveHit(inRow({ moveDrop: 'channel', moveId: 'devel', moveOk: 'false' }), topic), { kind: 'channel', id: 'devel', scope: '', ok: false, title: '' })
  })
  it('a row without a verdict refuses (never lit by default)', () => {
    assert.equal(moveHit(inRow({ moveDrop: 'channel', moveId: 'ops' }), topic).ok, false)
  })
  it('a reply drag hits a card, carrying its title for the toast', () => {
    assert.deepEqual(moveHit(inRow({ moveDrop: 'card', moveId: 't2', moveOk: 'true', moveTitle: 'two' }), reply), { kind: 'card', id: 't2', scope: '', ok: true, title: 'two' })
  })
  it('714c7028: a topic drag ALSO hits a card (a merge), carrying its title', () => {
    assert.deepEqual(moveHit(inRow({ moveDrop: 'card', moveId: 't2', moveOk: 'true', moveTitle: 'two' }), topic), { kind: 'card', id: 't2', scope: '', ok: true, title: 'two' })
  })
  it('the wrong kind of row, no row, no drag or no element is no hit', () => {
    assert.equal(moveHit(inRow({ moveDrop: 'channel', moveId: 'ops', moveOk: 'true' }), reply), null, 'a reply never drops on a channel')
    assert.equal(moveHit(inRow(null), topic), null, 'outside every row')
    assert.equal(moveHit(inRow({ moveDrop: 'channel', moveOk: 'true' }), topic), null, 'a row without an id')
    assert.equal(moveHit(inRow({ moveDrop: 'channel', moveId: 'ops', moveOk: 'true' }), null), null)
    assert.equal(moveHit(null, topic), null)
  })
  it('the same channel in two rail lists is two rows: the scope names the one under the pointer', () => {
    assert.equal(moveHit(inRow({ moveDrop: 'channel', moveId: 'ops', moveScope: 'flow', moveOk: 'true' }), topic).scope, 'flow')
  })
  it('sameHit ignores nothing but the title', () => {
    const a = { kind: 'channel', id: 'ops', scope: 'channels', ok: true, title: '' }
    assert.equal(sameHit(a, { ...a }), true)
    assert.equal(sameHit(a, { ...a, ok: false }), false)
    assert.equal(sameHit(a, { ...a, id: 'x' }), false)
    assert.equal(sameHit(a, { ...a, scope: 'flow' }), false)
    assert.equal(sameHit(a, { ...a, title: 'other' }), true)
    assert.equal(sameHit(null, null), true)
    assert.equal(sameHit(a, null), false)
  })
})

function rig({ hold = true } = {}) {
  const log = []
  let pending = null
  const d = createHandleDrag({
    onStart: (x, y) => log.push(['start', x, y]),
    onMove: (x, y) => log.push(['move', x, y]),
    onDrop: (x, y) => log.push(['drop', x, y]),
    onCancel: () => log.push(['cancel']),
    onHold: () => { log.push(['hold']); return hold },
    setTimer: (fn, ms) => { pending = { fn, ms }; return 1 },
    clearTimer: () => { pending = null },
  })
  return { d, log, fire: () => { const p = pending; pending = null; p && p.fn() }, pending: () => pending }
}
const mouse = (x, y, extra = {}) => ({ pointerId: 1, pointerType: 'mouse', button: 0, clientX: x, clientY: y, ...extra })
const finger = (x, y) => ({ pointerId: 7, pointerType: 'touch', clientX: x, clientY: y })

describe('createHandleDrag - the handle gesture', () => {
  it('the strip is ~3 mm and a mouse lifts after 4 px', () => {
    assert.equal(MOVE_HANDLE_PX, 12)
    assert.equal(MOVE_DRAG_START_PX, 4)
  })
  it('a mouse press that moves less than 4 px is a click, not a drag', () => {
    const { d, log } = rig()
    d.down(mouse(10, 10))
    d.move(mouse(12, 11))
    d.up(mouse(12, 11))
    assert.deepEqual(log, [])
    assert.equal(d.takeClick(), false)
  })
  it('a mouse press that travels lifts, follows and drops, then swallows one click', () => {
    const { d, log } = rig()
    d.down(mouse(10, 10))
    d.move(mouse(15, 10))
    d.move(mouse(40, 50))
    d.up(mouse(41, 52))
    assert.deepEqual(log, [['start', 15, 10], ['move', 15, 10], ['move', 40, 50], ['drop', 41, 52]])
    assert.equal(d.takeClick(), true)
    assert.equal(d.takeClick(), false, 'exactly once')
  })
  it('cancel while lifted cancels (Escape); cancel before a lift is silent', () => {
    const a = rig()
    a.d.down(mouse(0, 0))
    a.d.move(mouse(10, 0))
    a.d.cancel()
    a.d.up(mouse(10, 0))
    assert.deepEqual(a.log.map((e) => e[0]), ['start', 'move', 'cancel'], 'no drop after a cancel')
    const b = rig()
    b.d.down(mouse(0, 0))
    b.d.cancel()
    assert.deepEqual(b.log, [])
  })
  it('a right press or a second pointer is ignored', () => {
    const { d, log } = rig()
    assert.equal(d.down(mouse(0, 0, { button: 2 })), false)
    d.down(mouse(0, 0))
    d.move({ ...mouse(50, 50), pointerId: 2 })
    assert.deepEqual(log, [])
  })
  it('a finger lifts only after the hold, and follows from there', () => {
    const { d, log, fire, pending } = rig()
    d.down(finger(5, 100))
    assert.equal(pending().ms, MOVE_TOUCH_HOLD_MS)
    d.move(finger(8, 102))
    assert.deepEqual(log, [], 'within the slop, before the hold: nothing')
    fire()
    d.move(finger(60, 40))
    d.up(finger(60, 40))
    assert.deepEqual(log.map((e) => e[0]), ['hold', 'start', 'move', 'drop'])
  })
  it('a finger that slides before the hold is not holding: nothing starts', () => {
    const { d, log, pending } = rig()
    d.down(finger(5, 100))
    d.move(finger(5, 140))
    assert.equal(pending(), null, 'the hold timer is cleared')
    d.up(finger(5, 140))
    assert.deepEqual(log, [])
  })
  it('on a phone the hold does something else (the picker): no drag, the click is swallowed', () => {
    const { d, log, fire } = rig({ hold: false })
    d.down(finger(5, 100))
    fire()
    d.move(finger(90, 10))
    d.up(finger(90, 10))
    assert.deepEqual(log, [['hold']])
    assert.equal(d.takeClick(), true)
  })
})
