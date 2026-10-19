// r13-07: the key-list decisions of useScrollAnchor's afterPatch,
// afterPrepend and afterAppend (which rows to hold, when to stick to the
// bottom), tested without a DOM. The offset math has its own tests in
// newest-live.test.mjs (prepend) and view-prefs.test.mjs (append).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { anchorAfterAppend, appendPlan, patchStep, prependPlan } from '../../src/utils/scroll-anchor.mjs'

const own = (...keys) => (k) => keys.includes(k)

describe('patchStep: which way a feed change goes', () => {
  it('off when the anchor is disabled, whatever the order or capture', () => {
    assert.equal(patchStep({ enabled: false, newestLast: true, captured: true }), 'off')
    assert.equal(patchStep({ enabled: false, newestLast: false, captured: true }), 'off')
  })
  it('newest last appends, with or without a capture', () => {
    assert.equal(patchStep({ newestLast: true, captured: true }), 'append')
    assert.equal(patchStep({ newestLast: true, captured: false }), 'append')
  })
  it('newest first prepends only with a capture', () => {
    assert.equal(patchStep({ newestLast: false, captured: true }), 'prepend')
    assert.equal(patchStep({ newestLast: false, captured: false }), 'none')
    assert.equal(patchStep(), 'none')
  })
})

describe('prependPlan: newest first', () => {
  it('nothing above the old first row: none', () => {
    assert.deepEqual(prependPlan(['a', 'b'], ['a', 'b', 'c']), { step: 'none', added: 0 })
    assert.deepEqual(prependPlan([], ['a']), { step: 'none', added: 0 })
    assert.deepEqual(prependPlan(['a'], ['x', 'y']), { step: 'none', added: 0 })
  })
  it('rows from others arrive above: hold the visible rows, count them', () => {
    assert.deepEqual(prependPlan(['a', 'b'], ['y', 'x', 'a', 'b']), { step: 'hold', added: 2 })
  })
  it('our own send among the arrivals: jump to the newest end', () => {
    assert.deepEqual(prependPlan(['a', 'b'], ['y', 'x', 'a', 'b'], own('x')), { step: 'jump', added: 2 })
  })
  it('our own row below the arrivals does not jump', () => {
    assert.deepEqual(prependPlan(['a', 'b'], ['y', 'a', 'b'], own('a')), { step: 'hold', added: 1 })
  })
})

describe('appendPlan: newest last', () => {
  it('the first rows, or another list: land at the bottom', () => {
    assert.deepEqual(appendPlan([], ['a', 'b']), { step: 'bottom', added: 0, own: false })
    assert.deepEqual(appendPlan(['a'], ['x', 'y'], own('y')), { step: 'bottom', added: 0, own: false })
  })
  it('rows from others arrive below: hold, count them, not own', () => {
    assert.deepEqual(appendPlan(['a', 'b'], ['a', 'b', 'c', 'd']), { step: 'hold', added: 2, own: false })
  })
  it('our own send below: own, so the feed sticks to the bottom', () => {
    const plan = appendPlan(['a', 'b'], ['a', 'b', 'c', 'd'], own('d'))
    assert.deepEqual(plan, { step: 'hold', added: 2, own: true })
    assert.equal(anchorAfterAppend({ top: 10, own: plan.own, added: plan.added }).bottom, true)
  })
  it('our own row just above the arrivals is not new: not own', () => {
    assert.deepEqual(appendPlan(['a', 'b'], ['a', 'b', 'c'], own('b')), { step: 'hold', added: 1, own: false })
  })
  it('an older page above, nothing below: no new rows, not own', () => {
    assert.deepEqual(appendPlan(['a', 'b'], ['o', 'a', 'b'], own('a', 'b', 'o')), { step: 'hold', added: 0, own: false })
  })
  it('a patch in place (edit) keeps the list: hold, nothing added', () => {
    assert.deepEqual(appendPlan(['a', 'b'], ['a', 'b']), { step: 'hold', added: 0, own: false })
    assert.deepEqual(appendPlan(['a', 'b'], []), { step: 'hold', added: 0, own: false })
  })
  it('a reader scrolled up holds the row it looks at; others below only count', () => {
    const plan = appendPlan(['a', 'b'], ['a', 'b', 'c'])
    assert.deepEqual(anchorAfterAppend({ top: 50, atBottom: false, own: plan.own, added: plan.added, pill: 1, anchorBefore: 100, anchorAfter: 130 }),
      { bottom: false, top: 80, pill: 2 })
  })
})
