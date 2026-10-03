// CLE-77906 (owner, t1 topic 73c5d695) archived a topic by a swipe on mobile;
// HUM-10 (owner, t1 topic 2d09e9c2, 2026-10-03): a swipe LEFT archives, a
// swipe RIGHT opens the card's menu. The gesture rules: a mouse never swipes,
// the axis is decided after SWIPE_LOCK_PX, vertical stays a scroll, a short
// lift cancels, a direction the card does not offer is not ours, and a right
// swipe from the phone's Back zone stays Back.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { SWIPE_LOCK_PX, SWIPE_MAX_PX, SWIPE_MIN_PX, createSwipe, swipeInBackZone, swipeThresholdPx } from '../../src/utils/swipe-archive.mjs'

function rig({ width = 360, rtl = false, left = true, right = () => true } = {}) {
  const log = []
  const s = createSwipe({
    width: () => width,
    rtl: () => rtl,
    canLeft: () => left,
    canRight: right,
    onLock: (dir) => log.push(`lock ${dir}`),
    onMove: (dx, armed, dir) => log.push(`move ${dir} ${dx}${armed ? ' armed' : ''}`),
    onCommit: (dir, x, y) => log.push(`commit ${dir} ${x},${y}`),
    onCancel: () => log.push('cancel'),
  })
  const touch = (x, y) => ({ pointerType: 'touch', clientX: x, clientY: y, isPrimary: true })
  const ends = () => log.filter((l) => !l.startsWith('move'))
  return { s, log, touch, ends }
}

describe('swipeThresholdPx', () => {
  it('is 35% of the card, between the bounds', () => {
    assert.equal(swipeThresholdPx(300), 105)
    assert.equal(swipeThresholdPx(100), SWIPE_MIN_PX)
    assert.equal(swipeThresholdPx(1200), SWIPE_MAX_PX)
    assert.equal(swipeThresholdPx(0), SWIPE_MIN_PX)
  })
})

describe('swipeInBackZone', () => {
  it('is the start half of the screen (isMobileBackSwipe), mirrored in rtl', () => {
    assert.equal(swipeInBackZone(20, 390), true)
    assert.equal(swipeInBackZone(195, 390), true)
    assert.equal(swipeInBackZone(196, 390), false)
    assert.equal(swipeInBackZone(370, 390, true), true)
    assert.equal(swipeInBackZone(20, 390, true), false)
    assert.equal(swipeInBackZone(20, 0), false)
  })
})

describe('createSwipe', () => {
  it('a LEFT swipe past the threshold archives once, and swallows the click', () => {
    const { s, log, touch, ends } = rig()
    s.down(touch(300, 100))
    s.move(touch(300 - SWIPE_LOCK_PX - 2, 101))
    assert.equal(s.swiping, true)
    assert.equal(s.dir, 'archive')
    s.move(touch(150, 104))
    s.up()
    assert.deepEqual(ends(), ['lock archive', 'commit archive 150,104'])
    assert.ok(log.includes('move archive 150 armed'))
    assert.equal(s.takeClick(), true)
    assert.equal(s.takeClick(), false)
  })

  it('a RIGHT swipe past the threshold opens the menu where the finger lifted', () => {
    const { s, log, touch, ends } = rig()
    s.down(touch(220, 100))
    s.move(touch(240, 100))
    assert.equal(s.dir, 'menu')
    s.move(touch(360, 102))
    s.up()
    assert.deepEqual(ends(), ['lock menu', 'commit menu 360,102'])
    assert.ok(log.includes('move menu 140 armed'))
    assert.equal(s.takeClick(), true)
  })

  it('a right swipe the card refuses (the Back zone) is not ours: never locks', () => {
    const seen = []
    const { s, log, touch } = rig({ right: (x, y) => { seen.push([x, y]); return !swipeInBackZone(x, 390) } })
    s.down(touch(20, 100))
    s.move(touch(240, 100))
    s.up()
    assert.deepEqual(log, [])
    assert.deepEqual(seen, [[20, 100]])
    assert.equal(s.takeClick(), false)
  })

  it('no canRight: a right swipe is nothing', () => {
    const log = []
    const s = createSwipe({ width: () => 360, onCommit: () => log.push('commit') })
    s.down({ pointerType: 'touch', clientX: 220, clientY: 0 })
    s.move({ clientX: 380, clientY: 0 })
    s.up()
    assert.deepEqual(log, [])
  })

  it('a card that may not archive: a left swipe is nothing, a right one still opens the menu', () => {
    const { s, log, touch, ends } = rig({ left: false })
    s.down(touch(300, 100))
    s.move(touch(100, 100))
    s.up()
    assert.deepEqual(log, [])
    s.down(touch(220, 100))
    s.move(touch(370, 100))
    s.up()
    assert.deepEqual(ends(), ['lock menu', 'commit menu 370,100'])
  })

  it('a lift short of the threshold cancels (snaps back)', () => {
    const { s, touch, ends } = rig()
    s.down(touch(300, 100))
    s.move(touch(240, 100))
    s.up()
    assert.deepEqual(ends(), ['lock archive', 'cancel'])
  })

  it('dragging back under (or past) the start before the lift cancels', () => {
    const { s, log, touch } = rig()
    s.down(touch(300, 100))
    s.move(touch(100, 100))
    s.move(touch(330, 100))
    assert.equal(s.dx, 0)
    s.up()
    assert.equal(log.at(-1), 'cancel')
    assert.ok(!log.some((l) => l.startsWith('commit')))
  })

  it('a mostly vertical move is a scroll: never locks, never moves the card', () => {
    const { s, log, touch } = rig()
    s.down(touch(300, 100))
    s.move(touch(290, 140))
    s.move(touch(80, 150))
    s.up()
    assert.deepEqual(log, [])
    assert.equal(s.takeClick(), false)
  })

  it('rtl mirrors both directions', () => {
    const a = rig({ rtl: true })
    a.s.down(a.touch(100, 100))
    a.s.move(a.touch(260, 100))
    a.s.up()
    assert.equal(a.log.at(-1), 'commit archive 260,100')
    const m = rig({ rtl: true })
    m.s.down(m.touch(300, 100))
    m.s.move(m.touch(140, 100))
    m.s.up()
    assert.equal(m.log.at(-1), 'commit menu 140,100')
  })

  it('a mouse never swipes (desktop unchanged)', () => {
    const { s, log } = rig()
    s.down({ pointerType: 'mouse', clientX: 300, clientY: 0 })
    s.move({ pointerType: 'mouse', clientX: 0, clientY: 0 })
    s.up()
    assert.deepEqual(log, [])
  })

  it('pointercancel mid-swipe cancels; a second finger is ignored', () => {
    const { s, log, touch } = rig()
    s.down(touch(300, 100))
    s.move(touch(120, 100))
    s.move({ clientX: 0, clientY: 0, isPrimary: false })
    assert.equal(s.dx, 180)
    s.cancel()
    assert.equal(log.at(-1), 'cancel')
    assert.equal(s.swiping, false)
  })
})
