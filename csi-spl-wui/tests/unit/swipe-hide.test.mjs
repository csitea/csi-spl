// HUM-10 (owner, t1 topics 6fc56905 / 3e073a95, 2026-10-03): in the topic
// view a reply's swipe LEFT hides it (this device only); a thicker line
// stands where it was and a tap shows it again. The topic starter keeps the
// swipe-left archive and can never be hidden.
//
// Each rule carries a control: the same input with the one fact flipped,
// which must give the other answer - so a rule that always says 'hide' (or
// never does) fails here.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { createSwipe, swipeLeftAction } from '../../src/utils/swipe-archive.mjs'
import {
  HIDDEN_CARDS_KEY,
  HIDDEN_CARDS_MAX,
  collapseHiddenRuns,
  normalizeHiddenIds,
  readHiddenCards,
  withHiddenIds,
  withoutHiddenIds,
  writeHiddenCards,
} from '../../src/utils/hidden-cards.mjs'

const reply = { swipeOn: true, starter: false, mayArchive: false, inTopicPane: true }
const opener = { swipeOn: true, starter: true, mayArchive: true, inTopicPane: true }

/** A left swipe past the threshold on a card whose left is `leftDir()`. */
function swipeLeft(leftDir) {
  const log = []
  const s = createSwipe({
    width: () => 360,
    leftDir,
    canRight: () => true,
    onLock: (dir) => log.push(`lock ${dir}`),
    onCommit: (dir) => log.push(`commit ${dir}`),
    onCancel: () => log.push('cancel'),
  })
  s.down({ pointerType: 'touch', clientX: 300, clientY: 100, isPrimary: true })
  s.move({ clientX: 100, clientY: 102 })
  s.up()
  return log
}

describe('swipeLeftAction', () => {
  it('a reply in the topic view: LEFT hides', () => {
    assert.equal(swipeLeftAction(reply), 'hide')
  })
  it('control: the same reply outside the topic view is nothing', () => {
    assert.equal(swipeLeftAction({ ...reply, inTopicPane: false }), null)
  })
  it('control: no swipe at all (desktop, mouse) is nothing', () => {
    assert.equal(swipeLeftAction({ ...reply, swipeOn: false }), null)
  })
  it('the starter: LEFT archives (unchanged)', () => {
    assert.equal(swipeLeftAction(opener), 'archive')
    assert.equal(swipeLeftAction({ ...opener, inTopicPane: false }), 'archive')
  })
  it('control: the starter the viewer may not archive is nothing', () => {
    assert.equal(swipeLeftAction({ ...opener, mayArchive: false }), null)
  })
  it('the starter is never hide, whatever else holds', () => {
    for (const swipeOn of [true, false]) {
      for (const mayArchive of [true, false]) {
        for (const inTopicPane of [true, false]) {
          assert.notEqual(swipeLeftAction({ swipeOn, starter: true, mayArchive, inTopicPane }), 'hide')
        }
      }
    }
  })
  it('control: flipping only `starter` on the same card turns archive-or-nothing into hide', () => {
    assert.equal(swipeLeftAction({ ...opener, mayArchive: false, starter: false }), 'hide')
  })
})

describe('createSwipe with leftDir', () => {
  it('a reply: LEFT past the threshold commits hide', () => {
    assert.deepEqual(swipeLeft(() => swipeLeftAction(reply)), ['lock hide', 'commit hide'])
  })
  it('the starter: LEFT commits archive', () => {
    assert.deepEqual(swipeLeft(() => swipeLeftAction(opener)), ['lock archive', 'commit archive'])
  })
  it('control: a card with no left action never locks', () => {
    assert.deepEqual(swipeLeft(() => null), [])
  })
  it('a hide swipe measures its travel leftwards (dx >= 0), as archive does', () => {
    const seen = []
    const s = createSwipe({ width: () => 360, leftDir: () => 'hide', onMove: (dx, armed, dir) => seen.push([dx, dir]), onCommit: () => {} })
    s.down({ pointerType: 'touch', clientX: 300, clientY: 0 })
    s.move({ clientX: 250, clientY: 0 })
    assert.deepEqual(seen.at(-1), [50, 'hide'])
  })
})

/** an in-memory Storage */
function mem(init = {}) {
  const m = new Map(Object.entries(init))
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => void m.set(k, String(v)),
    removeItem: (k) => void m.delete(k),
    m,
  }
}

describe('hidden-cards store (this device)', () => {
  it('round-trips the hidden ids', () => {
    const s = mem()
    writeHiddenCards(['a', 'b'], s)
    assert.deepEqual(readHiddenCards(s), ['a', 'b'])
    writeHiddenCards([], s)
    assert.equal(s.m.has(HIDDEN_CARDS_KEY), false)
  })
  it('works without storage: no store, a throwing store, garbage', () => {
    assert.deepEqual(readHiddenCards(null), [])
    const bad = { getItem() { throw new Error('denied') }, setItem() { throw new Error('quota') }, removeItem() {} }
    assert.deepEqual(readHiddenCards(bad), [])
    assert.doesNotThrow(() => writeHiddenCards(['a'], bad))
    assert.deepEqual(readHiddenCards(mem({ [HIDDEN_CARDS_KEY]: '{not json' })), [])
    assert.deepEqual(readHiddenCards(mem({ [HIDDEN_CARDS_KEY]: '{"a":1}' })), [])
  })
  it('reads a throwing getItem and an unset key (null) as no hides', () => {
    assert.deepEqual(readHiddenCards({ getItem() { throw new Error('denied') } }), [])
    assert.deepEqual(readHiddenCards({ getItem: () => null }), [])
  })
  it('hide adds once, show removes; the list is capped', () => {
    assert.deepEqual(withHiddenIds(['a'], ['b', 'a']), ['b', 'a'])
    assert.deepEqual(withoutHiddenIds(['a', 'b', 'c'], ['b', 'c']), ['a'])
    assert.deepEqual(normalizeHiddenIds(['a', '', 3, 'a', 'b']), ['a', 'b'])
    const many = Array.from({ length: HIDDEN_CARDS_MAX + 5 }, (_, i) => `m${i}`)
    const kept = normalizeHiddenIds(many)
    assert.equal(kept.length, HIDDEN_CARDS_MAX)
    assert.equal(kept.at(-1), `m${HIDDEN_CARDS_MAX + 4}`)
  })
})

describe('collapseHiddenRuns', () => {
  const card = (id) => ({ key: id, msg: { msg_id: id }, i: 0 })
  it('one line per run of consecutive hidden cards, in place', () => {
    const items = [card('a'), card('b'), card('c'), card('d'), card('e')]
    const out = collapseHiddenRuns(items, (id) => id === 'b' || id === 'c' || id === 'e')
    assert.deepEqual(out.map((x) => x.hidden ? `line:${x.hidden.join('+')}` : x.key), ['a', 'line:b+c', 'd', 'line:e'])
  })
  it('control: nothing hidden passes every item through', () => {
    const items = [card('a'), { key: '__new-divider__', divider: true, i: -1 }, card('b')]
    assert.deepEqual(collapseHiddenRuns(items, () => false), items)
  })
  it('a divider between two hidden cards splits them into two lines', () => {
    const items = [card('a'), { key: '__new-divider__', divider: true, i: -1 }, card('b')]
    const out = collapseHiddenRuns(items, () => true)
    assert.deepEqual(out.map((x) => x.hidden ? 'line' : x.key), ['line', '__new-divider__', 'line'])
  })
})
