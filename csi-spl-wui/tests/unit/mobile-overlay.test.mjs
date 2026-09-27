// SPL-994: Back closes the top overlay first (utils/mobile-stack.mjs).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  MOBILE_OVERLAY_KEY,
  mobileOverlayOf,
  mobileOverlayPop,
  mobileOverlayState,
  mobileTaggedLevel,
} from '../../src/utils/mobile-stack.mjs'

const at = (position, id, level = 2) => ({ position, splLevel: level, ...(id === undefined ? {} : { [MOBILE_OVERLAY_KEY]: id }) })

describe('overlay history tag', () => {
  it('reads only a positive number', () => {
    assert.equal(mobileOverlayOf(null), null)
    assert.equal(mobileOverlayOf({}), null)
    assert.equal(mobileOverlayOf({ [MOBILE_OVERLAY_KEY]: null }), null)
    assert.equal(mobileOverlayOf({ [MOBILE_OVERLAY_KEY]: '3' }), null)
    assert.equal(mobileOverlayOf({ [MOBILE_OVERLAY_KEY]: 0 }), null)
    assert.equal(mobileOverlayOf({ [MOBILE_OVERLAY_KEY]: 3 }), 3)
  })
  it('keeps the router keys and the level, and clears to null (not absent)', () => {
    const s = mobileOverlayState({ position: 4, current: '/x', splLevel: 3 }, 7)
    assert.deepEqual(s, { position: 4, current: '/x', splLevel: 3, [MOBILE_OVERLAY_KEY]: 7 })
    assert.equal(mobileTaggedLevel(s), 3)
    const cleared = mobileOverlayState(s, null)
    assert.ok(MOBILE_OVERLAY_KEY in cleared)
    assert.equal(cleared[MOBILE_OVERLAY_KEY], null)
    /* vue-router spreads its cached state UNDER history.state: null must win */
    assert.equal(mobileOverlayOf({ ...s, ...cleared }), null)
  })
  it('does not mutate the state it copies', () => {
    const s = { position: 1 }
    mobileOverlayState(s, 2)
    assert.deepEqual(s, { position: 1 })
  })
})

describe('Back with overlays open', () => {
  it('no overlay: the router and the level handle it', () => {
    assert.deepEqual(mobileOverlayPop([], at(3), 4), { kind: 'none' })
    assert.deepEqual(mobileOverlayPop([], at(3, null), 4), { kind: 'none' })
  })
  it('one sheet: Back lands under it -> close it, level unchanged', () => {
    assert.deepEqual(mobileOverlayPop([1], at(4), 4), { kind: 'close', keep: 0 })
    assert.deepEqual(mobileOverlayPop([1], at(4, null), 4), { kind: 'close', keep: 0 })
  })
  it('a dialog over a sheet: Back closes the dialog only', () => {
    assert.deepEqual(mobileOverlayPop([1, 2], at(4, 1), 4), { kind: 'close', keep: 1 })
  })
  it('go(-2) from two overlays closes both', () => {
    assert.deepEqual(mobileOverlayPop([1, 2], at(4), 4), { kind: 'close', keep: 0 })
  })
  it('a pop onto the top overlay itself (a hash move) is not ours', () => {
    assert.deepEqual(mobileOverlayPop([1, 2], at(4, 2), 4), { kind: 'none' })
  })
  it('Back past every overlay entry: close them, the router navigates', () => {
    assert.deepEqual(mobileOverlayPop([1], at(3), 4), { kind: 'leave' })
  })
  it('an entry of an overlay that is gone is stepped past', () => {
    assert.deepEqual(mobileOverlayPop([], at(4, 9), 4), { kind: 'dead', back: false })
    assert.deepEqual(mobileOverlayPop([], at(4, 9), 5), { kind: 'dead', back: true })
    assert.deepEqual(mobileOverlayPop([1], at(4, 9), 4), { kind: 'dead', back: false })
  })
  it('no position known: treated as coming down onto the entry under the overlay', () => {
    assert.deepEqual(mobileOverlayPop([1], {}, null), { kind: 'close', keep: 0 })
  })
})
