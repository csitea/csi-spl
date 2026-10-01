// CLE-77871 (owner, t1 topic f20c6052: "the snack bar should work on mobile as
// well"): the "<what> · Undo" snackbar clock. Desktop keeps its window and the
// hover / focus hold; a touch UI gets at least UNDO_TOUCH_MIN_MS and holds
// while a finger is on it.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { UNDO_NOTE_MS, UNDO_TOUCH_MIN_MS, createUndoTimer, isTouchUi, undoWindowMs } from '../../src/utils/undo-timer.mjs'

/** A fake clock: set/clear plus advance(ms). */
function rig(opts) {
  let now = 0
  let next = 1
  const timers = new Map()
  let expired = 0
  const clock = createUndoTimer({
    ...opts,
    onExpire: () => { expired++ },
    set: (fn, ms) => { const id = next++; timers.set(id, { fn, at: now + ms }); return id },
    clear: (id) => { timers.delete(id) },
  })
  return {
    clock,
    get expired() { return expired },
    advance(ms) {
      now += ms
      for (const [id, t] of [...timers]) if (t.at <= now) { timers.delete(id); t.fn() }
    },
  }
}

describe('undoWindowMs', () => {
  it('desktop keeps the caller window', () => {
    assert.equal(undoWindowMs(700), 700)
    assert.equal(undoWindowMs(8000), 8000)
  })
  it('touch lifts a short window to at least 5 s', () => {
    assert.ok(UNDO_TOUCH_MIN_MS >= 5000)
    assert.equal(undoWindowMs(700, { touch: true }), UNDO_TOUCH_MIN_MS)
    assert.equal(undoWindowMs(8000, { touch: true }), 8000)
  })
  it('a note with no Undo is not lifted, and 0 stays the caller-owned 0', () => {
    assert.equal(undoWindowMs(UNDO_NOTE_MS, { touch: true, undo: false }), UNDO_NOTE_MS)
    assert.equal(undoWindowMs(0, { touch: true }), 0)
  })
})

describe('createUndoTimer', () => {
  it('desktop: dismisses after 0.7 s', () => {
    const r = rig({ duration: 700 })
    r.clock.arm()
    r.advance(699)
    assert.equal(r.expired, 0)
    r.advance(1)
    assert.equal(r.expired, 1)
  })

  it('touch: still up at 5 s, gone at the touch window', () => {
    const r = rig({ duration: 700, touch: true })
    r.clock.arm()
    r.advance(5000)
    assert.equal(r.expired, 0, 'a thumb has time to reach Undo')
    r.advance(UNDO_TOUCH_MIN_MS - 5000)
    assert.equal(r.expired, 1)
  })

  it('a finger down holds it; lifting re-arms the full window', () => {
    const r = rig({ duration: 700, touch: true })
    r.clock.arm()
    r.advance(UNDO_TOUCH_MIN_MS - 100)
    r.clock.hold('touch')
    r.advance(60000)
    assert.equal(r.expired, 0, 'held while touched')
    r.clock.release('touch')
    r.advance(UNDO_TOUCH_MIN_MS - 1)
    assert.equal(r.expired, 0, 'full window again, not the 100 ms left')
    r.advance(1)
    assert.equal(r.expired, 1)
  })

  it('a tap on a UI read as mouse-only switches to the touch window', () => {
    const r = rig({ duration: 700 })
    r.clock.arm()
    r.clock.touched()
    r.clock.hold('touch')
    r.clock.release('touch')
    r.advance(5000)
    assert.equal(r.expired, 0)
    r.advance(UNDO_TOUCH_MIN_MS)
    assert.equal(r.expired, 1)
  })

  it('holds are per reason: mouse leaving while focus is inside does not restart it', () => {
    const r = rig({ duration: 700 })
    r.clock.arm()
    r.clock.hold('hover')
    r.clock.hold('focus')
    r.clock.release('hover')
    assert.equal(r.clock.armed, false)
    r.advance(5000)
    assert.equal(r.expired, 0)
    r.clock.release('focus')
    assert.equal(r.clock.armed, true)
    r.advance(700)
    assert.equal(r.expired, 1)
  })

  it('a release with no hold does nothing; stop cancels', () => {
    const r = rig({ duration: 700 })
    r.clock.arm()
    r.advance(500)
    r.clock.release('hover')
    r.advance(200)
    assert.equal(r.expired, 1, 'a stray release did not restart the window')
    const s = rig({ duration: 700 })
    s.clock.arm()
    s.clock.stop()
    s.advance(10000)
    assert.equal(s.expired, 0)
  })

  it('duration 0 never arms (the caller owns timing)', () => {
    const r = rig({ duration: 0, touch: true })
    r.clock.arm()
    assert.equal(r.clock.armed, false)
  })
})

describe('isTouchUi', () => {
  const win = (q) => ({ matchMedia: (m) => ({ matches: q.includes(m) }) })
  it('a coarse pointer is touch; no hover alone (a pointer-less desktop) is not', () => {
    assert.equal(isTouchUi(win(['(pointer: coarse)', '(hover: none)'])), true)
    assert.equal(isTouchUi(win(['(hover: none)', '(pointer: none)'])), false)
    assert.equal(isTouchUi(win([])), false)
  })
  it('no window / no matchMedia is not touch', () => {
    assert.equal(isTouchUi(undefined), false)
    assert.equal(isTouchUi({}), false)
  })
})
