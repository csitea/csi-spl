// Spec 155 B6 (SPL-4186): the person's own note order and the checklist line
// moves (utils/note-order.mjs). Groups never mix: a pinned note moves among
// the pinned ones only (2.6).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { dropPosition, moveChecklistLine, movePosition, noteGroup, positionAt } from '../../src/utils/note-order.mjs'

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

describe('note-order: checklist lines', () => {
  it('moves a line one step and stops at the edges', () => {
    assert.deepEqual(moveChecklistLine(['a', 'b', 'c'], 2, -1), ['a', 'c', 'b'])
    assert.deepEqual(moveChecklistLine(['a', 'b', 'c'], 0, 1), ['b', 'a', 'c'])
    assert.equal(moveChecklistLine(['a', 'b'], 0, -1), null)
    assert.equal(moveChecklistLine(['a', 'b'], 1, 1), null)
  })
})
