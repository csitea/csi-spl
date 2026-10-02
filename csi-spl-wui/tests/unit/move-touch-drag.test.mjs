// HUM-10 (owner, t1 5a410ad5): a phone drags a topic card into another topic.
// The card's row gesture is createHandleDrag at the long-press timing
// (touch-ui.mjs), and the list scrolls near its edges (edgeScrollStep /
// createEdgeScroll). Without a browser: fake timers, fake frames.
// Run: node tests/unit/move-touch-drag.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  MOVE_EDGE_MAX_STEP,
  MOVE_EDGE_PX,
  createEdgeScroll,
  createHandleDrag,
  edgeScrollStep,
} from '../../src/utils/move-drag.mjs'
import { LONG_PRESS_MS, LONG_PRESS_SLOP_PX } from '../../src/utils/touch-ui.mjs'

/** The row gesture as MessageCard wires it on a phone, with a fake clock. */
function rowRig() {
  const calls = []
  let pending = null
  const g = createHandleDrag({
    holdMs: LONG_PRESS_MS,
    slopPx: LONG_PRESS_SLOP_PX,
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
const touch = (x, y) => ({ pointerId: 7, pointerType: 'touch', clientX: x, clientY: y })

describe('the phone row gesture - long press lifts, a swipe scrolls', () => {
  it('lifts only after the long-press time, never on touchstart', () => {
    const r = rowRig()
    r.g.down(touch(100, 300))
    assert.equal(r.pending.ms, LONG_PRESS_MS)
    assert.deepEqual(r.calls, [])
    r.fire()
    assert.equal(r.g.state, 'lifted')
    assert.deepEqual(r.calls, [['start', 100, 300]])
  })
  it('a drag after the hold moves and drops where the finger lifts', () => {
    const r = rowRig()
    r.g.down(touch(100, 300))
    r.fire()
    r.g.move(touch(110, 360))
    r.g.move(touch(120, 420))
    r.g.up(touch(120, 420))
    assert.deepEqual(r.calls.map((c) => c[0]), ['start', 'move', 'move', 'drop'])
    assert.deepEqual(r.calls.at(-1), ['drop', 120, 420])
    assert.equal(r.g.takeClick(), true, 'the release click does not open the topic')
  })
  it('CONTROL: a short touch-and-swipe lifts nothing and drops nothing (the list scrolls)', () => {
    const r = rowRig()
    r.g.down(touch(100, 300))
    r.g.move(touch(100, 300 - LONG_PRESS_SLOP_PX - 1))
    assert.equal(r.g.state, 'idle')
    assert.equal(r.pending, null, 'the hold timer is gone')
    r.g.move(touch(100, 150))
    r.g.up(touch(100, 150))
    assert.deepEqual(r.calls, [])
    assert.equal(r.g.takeClick(), false)
  })
  it('a pointercancel (the browser took the scroll) after a lift drops nothing', () => {
    const r = rowRig()
    r.g.down(touch(100, 300))
    r.fire()
    r.g.cancel()
    assert.deepEqual(r.calls.map((c) => c[0]), ['start', 'cancel'])
  })
})

describe('edgeScrollStep - the list scrolls near its edges only', () => {
  it('0 in the middle, up near the top, down near the bottom', () => {
    assert.equal(edgeScrollStep(400, 0, 800), 0)
    assert.ok(edgeScrollStep(10, 0, 800) < 0)
    assert.ok(edgeScrollStep(790, 0, 800) > 0)
  })
  it('faster the deeper in the band, capped at the max', () => {
    const shallow = edgeScrollStep(800 - MOVE_EDGE_PX + 5, 0, 800)
    const deep = edgeScrollStep(799, 0, 800)
    assert.ok(deep > shallow && shallow > 0, `${shallow} < ${deep}`)
    assert.equal(edgeScrollStep(900, 0, 800), MOVE_EDGE_MAX_STEP, 'past the edge = the max')
    assert.equal(edgeScrollStep(-50, 0, 800), -MOVE_EDGE_MAX_STEP)
  })
  it('the band follows the list box, not the viewport', () => {
    assert.ok(edgeScrollStep(110, 100, 700) < 0, "near the top of a list that starts 100 px down")
    assert.equal(edgeScrollStep(10, 100, 700), -MOVE_EDGE_MAX_STEP, "above the list = the max")
    assert.equal(edgeScrollStep(400, 100, 700), 0)
  })
  it('a short list keeps a middle: the band is at most a third of it', () => {
    assert.equal(edgeScrollStep(60, 0, 120), 0)
  })
  it('an empty or broken box never scrolls', () => {
    assert.equal(edgeScrollStep(10, 0, 0), 0)
    assert.equal(edgeScrollStep(Number.NaN, 0, 800), 0)
  })
})

describe('createEdgeScroll - one loop per drag', () => {
  function rig(y0 = 790) {
    const frames = []
    let top = 0
    const tracked = []
    const es = createEdgeScroll({
      box: () => ({ top: 0, bottom: 800, scrollBy: (dy) => { const b = top; top = Math.max(0, top + dy); return top !== b } }),
      onScroll: (x, y) => tracked.push([x, y]),
      frame: (fn) => { frames.push(fn); return frames.length },
      cancelFrame: () => { frames.length = 0 },
    })
    const step = () => frames.shift()?.()
    es.at(50, y0)
    return { es, frames, step, tracked, get top() { return top } }
  }
  it('scrolls down each frame near the bottom and re-reads the row under the finger', () => {
    const r = rig(790)
    r.step()
    r.step()
    assert.ok(r.top > 0)
    assert.deepEqual(r.tracked, [[50, 790], [50, 790]])
  })
  it('the middle scrolls nothing and re-reads nothing', () => {
    const r = rig(400)
    r.step()
    assert.equal(r.top, 0)
    assert.deepEqual(r.tracked, [])
  })
  it('one loop however often the finger moves; stop ends it', () => {
    const r = rig(790)
    r.es.at(50, 795)
    r.es.at(50, 799)
    assert.equal(r.frames.length, 1)
    r.es.stop()
    assert.equal(r.es.running, false)
    assert.equal(r.frames.length, 0)
  })
})
