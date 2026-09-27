// SPL-989: the phone shell's pure rules (utils/mobile-stack.mjs).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  MOBILE_STACK_MAX_PX,
  MOBILE_STACK_QUERY,
  MOBILE_LEVEL_KEY,
  MOBILE_BELOW_KEY,
  isMobileBackSwipe,
  isMobileFrontDoor,
  mobileHasBelow,
  mobileHistoryStep,
  mobileInitialLevel,
  mobileLevelOf,
  mobileTagState,
  mobileTaggedLevel,
} from '../../src/utils/mobile-stack.mjs'

describe('mobile stack levels', () => {
  it('820 px is the last mobile width', () => {
    assert.equal(MOBILE_STACK_MAX_PX, 820)
    assert.equal(MOBILE_STACK_QUERY, '(max-width: 820px)')
  })
  it('a topic open is level 3 whatever else', () => {
    assert.equal(mobileLevelOf({ home: true, topicOpen: true }), 3)
    assert.equal(mobileLevelOf({ home: false, topicOpen: true }), 3)
    assert.equal(mobileLevelOf({ home: true, topicOpen: false }), 1)
    assert.equal(mobileLevelOf({ home: false, topicOpen: false }), 2)
  })
  it('the front door opens on the left panel, deep links where they point', () => {
    for (const p of ['/', '', '/fi', '/bg/', '/pt-BR']) assert.equal(mobileInitialLevel(p, {}), 1, p)
    assert.equal(isMobileFrontDoor('/lobby'), false)
    assert.equal(mobileInitialLevel('/channel/general', {}), 2)
    assert.equal(mobileInitialLevel('/fi/dm/HUM-1%40box', {}), 2)
    assert.equal(mobileInitialLevel('/channel/general', { topic: 'abc' }), 3)
    assert.equal(mobileInitialLevel('/lobby', { in: 'abc' }), 3)
    assert.equal(mobileInitialLevel('/', { topic: 'abc' }), 3)
  })
})

describe('mobile stack history tags', () => {
  it('reads only its own keys and keeps the router keys', () => {
    assert.equal(mobileTaggedLevel(null), null)
    assert.equal(mobileTaggedLevel({ position: 3 }), null)
    assert.equal(mobileTaggedLevel({ [MOBILE_LEVEL_KEY]: 2 }), 2)
    assert.equal(mobileTaggedLevel({ [MOBILE_LEVEL_KEY]: 7 }), null)
    const s = mobileTagState({ position: 4, current: '/lobby' }, 3, 2)
    assert.deepEqual(s, { position: 4, current: '/lobby', [MOBILE_LEVEL_KEY]: 3, [MOBILE_BELOW_KEY]: 2 })
    assert.equal(mobileHasBelow(s), true)
    assert.equal(mobileHasBelow(mobileTagState(s, 2, 0)), false)
    assert.equal(mobileHasBelow(mobileTagState(s, 2)), true, 'below undefined keeps the old key')
  })
  it('a fresh entry is tagged, a rise on the same entry is pushed, a fall is re-tagged', () => {
    assert.equal(mobileHistoryStep(null, 2), 'tag')
    assert.equal(mobileHistoryStep(1, 3), 'push')
    assert.equal(mobileHistoryStep(1, 2), 'push')
    assert.equal(mobileHistoryStep(3, 2), 'tag')
    assert.equal(mobileHistoryStep(2, 2), 'none')
  })
})

describe('mobile back swipe', () => {
  const w = 390
  it('a right swipe from the left half pops', () => {
    assert.equal(isMobileBackSwipe({ x0: 20, y0: 300, x1: 120, y1: 310, width: w }), true)
  })
  it('short, vertical, leftward or right-half starts do not', () => {
    assert.equal(isMobileBackSwipe({ x0: 20, y0: 300, x1: 60, y1: 300, width: w }), false)
    assert.equal(isMobileBackSwipe({ x0: 20, y0: 300, x1: 120, y1: 400, width: w }), false)
    assert.equal(isMobileBackSwipe({ x0: 120, y0: 300, x1: 20, y1: 300, width: w }), false)
    assert.equal(isMobileBackSwipe({ x0: 300, y0: 300, x1: 390, y1: 300, width: w }), false)
    assert.equal(isMobileBackSwipe({ x0: 20, y0: 300, x1: 120, y1: 300, width: 0 }), false)
  })
  it('rtl mirrors it', () => {
    assert.equal(isMobileBackSwipe({ x0: 370, y0: 300, x1: 270, y1: 300, width: w, rtl: true }), true)
    assert.equal(isMobileBackSwipe({ x0: 20, y0: 300, x1: 120, y1: 300, width: w, rtl: true }), false)
  })
})
