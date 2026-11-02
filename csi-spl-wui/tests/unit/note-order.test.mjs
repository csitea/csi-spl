// Spec 155 B6 (SPL-4186): the person's own note order and the checklist line
// moves (utils/note-order.mjs). Groups never mix: a pinned note moves among
// the pinned ones only (2.6).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { compareNotes, dropPosition, moveChecklistLine, movePosition, noteGroup, notePriority, positionAt } from '../../src/utils/note-order.mjs'

const n = (id, position, extra = {}) => ({ id, position, pinned: false, archived: false, updated_at: '2026-10-29T00:00:00Z', ...extra })
const LIST = [n('p1', 1, { pinned: true }), n('p2', 2, { pinned: true }), n('a', 3), n('b', 4), n('c', 6), n('x', 5, { archived: true })]
/** the ids of a group in drawn order once `id` takes `pos` */
const orderWith = (id, pos, group) => LIST.map((r) => (r.id === id ? { ...r, position: pos } : r))
  .filter((r) => noteGroup(r) === group).sort((a, b) => a.position - b.position).map((r) => r.id)

describe('note-order: groups', () => {
  it('archived beats pinned; pinned before the rest', () => {
    assert.equal(noteGroup(n('q', 1, { pinned: true, archived: true })), 'archived')
    assert.equal(noteGroup(n('q', 1, { pinned: true })), 'pinned')
    assert.equal(noteGroup(n('q', 1)), 'rest')
  })
})

describe('note-order: Move up / Move down (Alt+Up / Alt+Down)', () => {
  it('moves one step inside the group, never past its edge', () => {
    assert.deepEqual(orderWith('b', movePosition(LIST, 'b', -1), 'rest'), ['b', 'a', 'c'])
    assert.deepEqual(orderWith('a', movePosition(LIST, 'a', 1), 'rest'), ['b', 'a', 'c'])
    assert.deepEqual(orderWith('b', movePosition(LIST, 'b', 1), 'rest'), ['a', 'c', 'b'])
    assert.equal(movePosition(LIST, 'a', -1), null, 'the first of the rest does not jump into Pinned')
    assert.equal(movePosition(LIST, 'c', 1), null)
    assert.equal(movePosition(LIST, 'p2', 1), null, 'the last pinned does not leave Pinned')
    assert.equal(movePosition(LIST, 'x', -1), null, 'alone in Archived')
    assert.equal(movePosition(LIST, 'nope', 1), null)
  })
})

describe('note-order: drag and drop', () => {
  it('drops before or after a row of the same group', () => {
    assert.deepEqual(orderWith('c', dropPosition(LIST, 'c', 'a'), 'rest'), ['c', 'a', 'b'])
    assert.deepEqual(orderWith('a', dropPosition(LIST, 'a', 'c', true), 'rest'), ['b', 'c', 'a'])
    assert.deepEqual(orderWith('a', dropPosition(LIST, 'a', 'b', true), 'rest'), ['b', 'a', 'c'])
  })
  it('refuses a drop on another group, on itself, or one that moves nothing', () => {
    assert.equal(dropPosition(LIST, 'a', 'p1'), null)
    assert.equal(dropPosition(LIST, 'a', 'a'), null)
    assert.equal(dropPosition(LIST, 'a', 'b'), null, 'a is already before b')
    assert.equal(dropPosition(LIST, 'b', 'a', true), null, 'b is already after a')
  })
  it('positionAt: the top, the bottom and between', () => {
    const rows = [n('a', 2), n('b', 4)]
    assert.equal(positionAt(rows, 0), 1)
    assert.equal(positionAt(rows, 1), 3)
    assert.equal(positionAt(rows, 2), 5)
    assert.equal(positionAt([], 0), 0)
  })
})

describe('note-order: priority (spec 155 2.9, SPL-4652)', () => {
  const P = [n('u', 9, { priority: 1 }), n('a', 1), n('b', 2, { priority: 5 }), n('c', 3, { priority: 2 }), n('d', 4, { priority: 2 }), n('pin', 20, { pinned: true })]
  const drawn = (list) => [...list].sort(compareNotes).map((r) => r.id)
  it('reads 1..5, and 5 for anything else', () => {
    for (const p of [1, 2, 3, 4, 5]) assert.equal(notePriority({ priority: p }), p)
    for (const p of [undefined, null, 0, 6, 1.5, 'x']) assert.equal(notePriority({ priority: p }), 5, String(p))
  })
  it('draws pinned first, then priority 1 first, then the own order', () => {
    assert.deepEqual(drawn(P), ['pin', 'u', 'c', 'd', 'a', 'b'])
  })
  it('a pinned 5 stays above an unpinned 1', () => {
    assert.deepEqual(drawn([n('x', 1, { priority: 1 }), n('y', 2, { pinned: true, priority: 5 })]), ['y', 'x'])
  })
  it('Move stays among the notes of the same priority', () => {
    assert.equal(movePosition(P, 'c', -1), null, 'the first at 2 does not jump above the 1')
    assert.equal(movePosition(P, 'd', 1), null, 'the last at 2 does not fall into the 5s')
    assert.equal(movePosition(P, 'u', 1), null, 'alone at 1')
    assert.equal(movePosition(P, 'd', -1), 2, 'd goes above c')
  })
  it('a drop on another priority moves nothing', () => {
    assert.equal(dropPosition(P, 'a', 'u'), null)
    assert.equal(dropPosition(P, 'u', 'a'), null)
    assert.equal(dropPosition(P, 'd', 'b', true), null)
    assert.equal(dropPosition(P, 'd', 'c'), 2, 'twin: the same priority still moves')
  })
})

describe('note-order: checklist lines', () => {
  it('moves a line one step and stops at the edges', () => {
    assert.deepEqual(moveChecklistLine(['a', 'b', 'c'], 2, -1), ['a', 'c', 'b'])
    assert.deepEqual(moveChecklistLine(['a', 'b', 'c'], 0, 1), ['b', 'a', 'c'])
    assert.equal(moveChecklistLine(['a', 'b'], 0, -1), null)
    assert.equal(moveChecklistLine(['a', 'b'], 1, 1), null)
  })
})
