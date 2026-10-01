// CLE-77906 (owner, t1 topic 73c5d695): a right swipe on a topic card (cards
// view) or on the topic's opening message (topic view) archives the topic on
// mobile. The gesture rules: a mouse never swipes, the axis is decided after
// SWIPE_LOCK_PX, vertical stays a scroll, a short lift cancels.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { SWIPE_LOCK_PX, SWIPE_MAX_PX, SWIPE_MIN_PX, createSwipe, swipeThresholdPx } from '../../src/utils/swipe-archive.mjs'

function rig({ width = 360, rtl = false } = {}) {
  const log = []
  const s = createSwipe({
    width: () => width,
    rtl: () => rtl,
    onLock: () => log.push('lock'),
    onMove: (dx, armed) => log.push(`move ${dx}${armed ? ' armed' : ''}`),
    onCommit: () => log.push('commit'),
    onCancel: () => log.push('cancel'),
  })
  const touch = (x, y) => ({ pointerType: 'touch', clientX: x, clientY: y, isPrimary: true })
  return { s, log, touch }
}

describe('swipeThresholdPx', () => {
  it('is 35% of the card, between the bounds', () => {
    assert.equal(swipeThresholdPx(300), 105)
    assert.equal(swipeThresholdPx(100), SWIPE_MIN_PX)
    assert.equal(swipeThresholdPx(1200), SWIPE_MAX_PX)
    assert.equal(swipeThresholdPx(0), SWIPE_MIN_PX)
  })
})

describe('createSwipe', () => {
  it('a right swipe past the threshold archives once, and swallows the click', () => {
    const { s, log, touch } = rig()
    s.down(touch(20, 100))
    s.move(touch(20 + SWIPE_LOCK_PX + 2, 101))
    assert.equal(s.swiping, true)
    s.move(touch(170, 104))
    s.up()
    assert.deepEqual(log.filter((l) => !l.startsWith('move')), ['lock', 'commit'])
    assert.ok(log.includes('move 150 armed'))
    assert.equal(s.takeClick(), true)
    assert.equal(s.takeClick(), false)
  })

  it('a lift short of the threshold cancels (snaps back)', () => {
    const { s, log, touch } = rig()
    s.down(touch(20, 100))
    s.move(touch(80, 100))
    s.up()
    assert.deepEqual(log.filter((l) => !l.startsWith('move')), ['lock', 'cancel'])
  })

  it('dragging back under the threshold before the lift cancels', () => {
    const { s, log, touch } = rig()
    s.down(touch(20, 100))
    s.move(touch(200, 100))
    s.move(touch(40, 100))
    s.up()
    assert.equal(log.at(-1), 'cancel')
    assert.ok(!log.includes('commit'))
  })

  it('a mostly vertical move is a scroll: never locks, never moves the card', () => {
    const { s, log, touch } = rig()
    s.down(touch(20, 100))
    s.move(touch(30, 140))
    s.move(touch(220, 150))
    s.up()
    assert.deepEqual(log, [])
    assert.equal(s.takeClick(), false)
  })

  it('a left swipe is not ours', () => {
    const { s, log, touch } = rig()
    s.down(touch(200, 100))
    s.move(touch(60, 100))
    s.up()
    assert.deepEqual(log, [])
  })

  it('rtl mirrors the direction', () => {
    const { s, log, touch } = rig({ rtl: true })
    s.down(touch(300, 100))
    s.move(touch(140, 100))
    s.up()
    assert.equal(log.at(-1), 'commit')
  })

  it('a mouse never swipes (desktop unchanged)', () => {
    const { s, log } = rig()
    s.down({ pointerType: 'mouse', clientX: 0, clientY: 0 })
    s.move({ pointerType: 'mouse', clientX: 300, clientY: 0 })
    s.up()
    assert.deepEqual(log, [])
  })

  it('pointercancel mid-swipe cancels; a second finger is ignored', () => {
    const { s, log, touch } = rig()
    s.down(touch(20, 100))
    s.move(touch(200, 100))
    s.move({ clientX: 0, clientY: 0, isPrimary: false })
    assert.equal(s.dx, 180)
    s.cancel()
    assert.equal(log.at(-1), 'cancel')
    assert.equal(s.swiping, false)
  })
})
