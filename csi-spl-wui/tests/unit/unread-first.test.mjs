import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { unreadFirst } from '../../src/utils/unread-first.mjs'

/* rows: id + unread + newest unread time; today's order is the array order */
const R = (id, n, at = '') => ({ id, n, at })
const ids = (rows) => rows.map((r) => r.id)
const n = (r) => r.n
const at = (r) => r.at

describe('unreadFirst: unread items at the edge new posts go to (SPL-2506)', () => {
  const today = [R('a', 0), R('b', 2, '2026-10-18T01:00:00Z'), R('c', 0), R('d', 5, '2026-10-18T00:00:00Z'), R('e', 1, '2026-10-18T02:00:00Z'), R('f', 0)]

  it('prepend (newest first): the most unread at the very top, then the next; read rows keep their order below', () => {
    assert.deepEqual(ids(unreadFirst(today, n, { at })), ['d', 'b', 'e', 'a', 'c', 'f'])
  })
  it('append (newest last): the mirror, the most unread at the very bottom; read rows keep their order above', () => {
    assert.deepEqual(ids(unreadFirst(today, n, { atEnd: true, at })), ['a', 'c', 'f', 'e', 'b', 'd'])
  })
  it('a tie goes to the newest unread, nearest the edge', () => {
    const tie = [R('old', 2, '2026-10-18T00:00:00Z'), R('x', 0), R('new', 2, '2026-10-18T03:00:00Z')]
    assert.deepEqual(ids(unreadFirst(tie, n, { at })), ['new', 'old', 'x'])
    assert.deepEqual(ids(unreadFirst(tie, n, { at, atEnd: true })), ['x', 'old', 'new'])
  })
  it('a tie with no time keeps today\'s order (top first; at the end the earlier row stays nearest the edge... mirrored)', () => {
    const tie = [R('p', 1), R('q', 1), R('r', 0)]
    assert.deepEqual(ids(unreadFirst(tie, n)), ['p', 'q', 'r'])
    assert.deepEqual(ids(unreadFirst([R('r', 0), R('p', 1), R('q', 1)], n, { atEnd: true })), ['r', 'p', 'q'])
  })
  it('nothing unread: the same array, unchanged (control)', () => {
    const read = [R('a', 0), R('b', 0)]
    assert.equal(unreadFirst(read, n), read)
    assert.deepEqual(ids(unreadFirst(read, n, { atEnd: true })), ['a', 'b'])
  })
  it('junk counts read as 0; a non-array is an empty list', () => {
    assert.deepEqual(ids(unreadFirst([R('a', Number.NaN), R('b', -3), R('c', 1)], n)), ['c', 'a', 'b'])
    assert.deepEqual(unreadFirst(null, n), [])
  })
})
