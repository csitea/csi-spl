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
  isStaleLoginStep,
  mobileAfterNavStep,
  mobileBackStep,
  mobileHasBelow,
  mobileHistoryStep,
  mobileInPlaceStep,
  mobileInitialLevel,
  mobileLoginFrontDoor,
  mobileLevelOf,
  mobileOverlayCloseStep,
  mobileOverlayOf,
  mobilePopDropsTopic,
  mobilePushPlan,
  mobileRecordStep,
  mobileStaleLoginLoad,
  mobileStaleTopicUrl,
  mobileStatePosition,
  mobileSwipeStart,
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

describe('CLE-77882: an open-in-place is one history entry', () => {
  it('the topic opening on the fresh route entry is a tag, not a second push', () => {
    assert.equal(mobileInPlaceStep(mobileHistoryStep(2, 3), 3, true), 'tag')
  })
  it('CONTROL: without an open-in-place pending, a topic opening pushes (Back closes the thread)', () => {
    assert.equal(mobileInPlaceStep(mobileHistoryStep(2, 3), 3, false), 'push')
  })
  it('only the step UP to the thread is folded; other steps pass through', () => {
    assert.equal(mobileInPlaceStep('push', 2, true), 'push')
    assert.equal(mobileInPlaceStep('tag', 1, true), 'tag')
    assert.equal(mobileInPlaceStep('none', 3, true), 'none')
  })
})

describe('c78fb3ec: an entry below level 3 never names a topic', () => {
  const T = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  it('a level-2 entry drops topic and in, keeping the path and every other parameter', () => {
    assert.equal(mobileStaleTopicUrl(`https://x.example.com/channel/lobby?topic=${T}`, 2), '/channel/lobby')
    assert.equal(mobileStaleTopicUrl(`https://x.example.com/fi/channel/a?q=hi&topic=${T}&in=p#m`, 1), '/fi/channel/a?q=hi#m')
    assert.equal(mobileStaleTopicUrl('https://x.example.com/channel/a?in=p', 2), '/channel/a')
  })
  it('CONTROL: level 3 (the topic itself) and untagged entries keep their URL', () => {
    assert.equal(mobileStaleTopicUrl(`https://x.example.com/channel/lobby?topic=${T}`, 3), null)
    assert.equal(mobileStaleTopicUrl(`https://x.example.com/channel/lobby?topic=${T}`, null), null)
  })
  it('nothing to drop, or no URL, is null', () => {
    assert.equal(mobileStaleTopicUrl('https://x.example.com/channel/lobby?q=hi', 2), null)
    assert.equal(mobileStaleTopicUrl('not a url', 2), null)
  })
})

describe('087 T003: Back never lands on the sign-in page while signed in', () => {
  it('/login under any locale prefix, signed in, is a stale step', () => {
    assert.equal(isStaleLoginStep('/login', 'in'), true)
    assert.equal(isStaleLoginStep('/login/', 'in'), true)
    assert.equal(isStaleLoginStep('/fi/login', 'in'), true)
    assert.equal(isStaleLoginStep('/sr-Latn/login', 'in'), true)
    assert.equal(isStaleLoginStep('/login?redirect=%2Fchannel%2Flobby', 'in'), true)
  })
  it('CONTROL: signed out, still loading or unknown keeps the sign-in page', () => {
    for (const s of ['out', 'loading', 'unknown', '', undefined]) assert.equal(isStaleLoginStep('/login', s), false, String(s))
  })
  it('CONTROL: any other path is not a login step', () => {
    for (const p of ['/', '/fi', '/channel/login', '/login/x', '/loginx', '/help/login', '', null]) assert.equal(isStaleLoginStep(p, 'in'), false, String(p))
  })
  it('the front door keeps the locale prefix', () => {
    assert.equal(mobileLoginFrontDoor('/login'), '/')
    assert.equal(mobileLoginFrontDoor('/fi/login/'), '/fi')
    assert.equal(mobileLoginFrontDoor('/sr-Latn/login?x=1'), '/sr-Latn')
    assert.equal(mobileLoginFrontDoor('/channel/lobby'), '/')
  })
})

// r14-07 (SPL-2696): the stack decisions useMobileStack.ts applies.
describe('r14-07: Back by the chevron or a swipe', () => {
  const s = (o) => ({ mobile: true, overlays: 0, level: 2, hasBelow: false, up: () => false, ...o })
  it('the top overlay goes first, then an entry of ours below, else down in place', () => {
    assert.equal(mobileBackStep(s({ overlays: 1, hasBelow: true, level: 3 })), 'overlay')
    assert.equal(mobileBackStep(s({ hasBelow: true, level: 3 })), 'history')
    assert.equal(mobileBackStep(s({ level: 3 })), 'down')
    assert.equal(mobileBackStep(s({ level: 2 })), 'down')
  })
  it('CONTROL: not a phone, or level 1, does nothing', () => {
    assert.equal(mobileBackStep(s({ mobile: false, overlays: 1, level: 3 })), 'none')
    assert.equal(mobileBackStep(s({ level: 1, hasBelow: true })), 'none')
  })
  it('a page level above a level-2 deep link steps up first, and is asked only there', () => {
    let asked = 0
    const up = (r) => () => { asked++; return r }
    assert.equal(mobileBackStep(s({ up: up(true) })), 'none')
    assert.equal(mobileBackStep(s({ up: up(false) })), 'down')
    assert.equal(asked, 2)
    mobileBackStep(s({ level: 3, up: up(true) }))
    mobileBackStep(s({ hasBelow: true, up: up(true) }))
    assert.equal(asked, 2, 'up() is not asked on level 3 or with an entry below')
  })
})

describe('r14-07: recording a level that moved without a popstate', () => {
  it('folds the in-place push to the thread and uses the pending open up', () => {
    assert.deepEqual(mobileRecordStep(2, 3, true), { step: 'tag', clearInPlace: true })
    assert.deepEqual(mobileRecordStep(2, 3, false), { step: 'push', clearInPlace: false })
    assert.deepEqual(mobileRecordStep(null, 2, true), { step: 'tag', clearInPlace: false })
    assert.deepEqual(mobileRecordStep(3, 3, false), { step: 'none', clearInPlace: false })
  })
  it('a push leaves the entry below without the topic; the new entry keeps it', () => {
    const href = 'https://x.example.com/channel/lobby?topic=abc'
    const p = mobilePushPlan(href, { position: 4, splOverlay: 7 }, 3, 2)
    assert.equal(p.under, '/channel/lobby')
    assert.equal(p.url, href)
    assert.deepEqual(p.state, { position: 4, splOverlay: null, [MOBILE_LEVEL_KEY]: 3, [MOBILE_BELOW_KEY]: 2 })
  })
  it('CONTROL: nothing stale to drop keeps the URL; an untagged entry pushes over 1', () => {
    const p = mobilePushPlan('https://x.example.com/channel/lobby', null, 2, null)
    assert.equal(p.under, null)
    assert.equal(p.url, undefined)
    assert.equal(p.state[MOBILE_BELOW_KEY], 1)
  })
})

describe('r14-07: route navigations, popstates and overlays', () => {
  it('after a navigation: a duplicate on a phone shows level 2, a fresh entry is tagged', () => {
    assert.equal(mobileAfterNavStep('duplicated', true, null), 'push')
    assert.equal(mobileAfterNavStep('duplicated', false, null), 'none')
    assert.equal(mobileAfterNavStep('other', true, null), 'none')
    assert.equal(mobileAfterNavStep(null, true, null), 'tag')
    assert.equal(mobileAfterNavStep(null, true, 2), 'none', 'an entry tagged already is not re-tagged')
  })
  it('a popped entry drops its stale topic unless the shell swallows the event', () => {
    assert.equal(mobilePopDropsTopic({ kind: 'none' }), true)
    assert.equal(mobilePopDropsTopic({ kind: 'leave' }), true)
    assert.equal(mobilePopDropsTopic({ kind: 'dead', back: true }), true)
    assert.equal(mobilePopDropsTopic({ kind: 'close', keep: 0 }), false)
    assert.equal(mobilePopDropsTopic({ kind: 'dead', back: false }), false)
  })
  it('an overlay that closed: back over its current entry, drop a gone one, wait under another', () => {
    assert.equal(mobileOverlayCloseStep([1, 2], 2, 2), 'back')
    assert.equal(mobileOverlayCloseStep([1, 2], 2, null), 'drop')
    assert.equal(mobileOverlayCloseStep([1, 2], 1, 2), 'wait')
    assert.equal(mobileOverlayCloseStep([1, 2], 3, 2), 'none')
  })
  it('history position and overlay id read only well-formed values', () => {
    assert.equal(mobileStatePosition({ position: 5 }), 5)
    assert.equal(mobileStatePosition({ position: '5' }), null)
    assert.equal(mobileStatePosition(null), null)
    assert.equal(mobileOverlayOf({ splOverlay: 3 }), 3)
  })
})

describe('r14-07: swipe start and the stale login load', () => {
  it('one finger on an active stack starts a swipe; anything else does not', () => {
    assert.deepEqual(mobileSwipeStart(true, [{ clientX: 10, clientY: 20 }]), { x: 10, y: 20 })
    assert.equal(mobileSwipeStart(false, [{ clientX: 10, clientY: 20 }]), null)
    assert.equal(mobileSwipeStart(true, [{ clientX: 1, clientY: 1 }, { clientX: 2, clientY: 2 }]), null)
    assert.equal(mobileSwipeStart(true, []), null)
  })
  it('only a back_forward load of /login on a phone waits for the session', () => {
    assert.equal(mobileStaleLoginLoad('back_forward', true, '/fi/login'), true)
    assert.equal(mobileStaleLoginLoad('navigate', true, '/login'), false)
    assert.equal(mobileStaleLoginLoad('back_forward', false, '/login'), false)
    assert.equal(mobileStaleLoginLoad('back_forward', true, '/channel/lobby'), false)
  })
})
