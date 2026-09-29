// owner, topic e00da93b: "the sorting controls should be removed, and just each
// column should have the up or down triangle to show whether or not the sort is
// applied on this column". A header click: ▲ ascending, ▼ descending, then back
// to the default (Updated, newest first); the sort lives in ?sort=&dir=.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { nextSort, sortFromQuery, hubSort, sortSheet, SHEET_COLUMNS, DEFAULT_SORT } from '../../src/utils/issues-view.mjs'

const mk = (n, o = {}) => ({ key: `SPL-${n}`, title: `t${n}`, status: 'todo', priority: 3, level: 2, assignee: '', labels: [], deadline: '', updated_at: `2026-09-2${n}T10:00:00Z`, ...o })
const keys = (l) => l.map((i) => i.key)

describe('the sheet sort', () => {
  it('a header click cycles asc -> desc -> default; another column starts at asc', () => {
    let s = { col: '', dir: '' }
    s = nextSort('title', s); assert.deepEqual(s, { col: 'title', dir: 'asc' })
    s = nextSort('title', s); assert.deepEqual(s, { col: 'title', dir: 'desc' })
    s = nextSort('title', s); assert.deepEqual(s, { col: '', dir: '' })
    assert.deepEqual(nextSort('deadline', { col: 'title', dir: 'desc' }), { col: 'deadline', dir: 'asc' })
    assert.deepEqual(nextSort('nope', { col: 'title', dir: 'asc' }), { col: '', dir: '' })
  })
  it('reads ?sort=&dir= and refuses anything else (CONTROL)', () => {
    assert.deepEqual(sortFromQuery({ sort: 'title', dir: 'asc' }), { col: 'title', dir: 'asc' })
    assert.deepEqual(sortFromQuery({ sort: ['status'], dir: ['desc'] }), { col: 'status', dir: 'desc' })
    assert.deepEqual(sortFromQuery({ sort: 'title', dir: 'up' }), { col: '', dir: '' })
    assert.deepEqual(sortFromQuery({ sort: 'x', dir: 'asc' }), { col: '', dir: '' })
  })
  it('asks the hub only for a sort it knows', () => {
    assert.equal(hubSort({ col: 'deadline', dir: 'asc' }), 'deadline')
    assert.equal(hubSort({ col: 'title', dir: 'asc' }), 'updated')
    // SPL-1181: no explicit sort = the product default, priority.
    assert.equal(hubSort({ col: '', dir: '' }), 'priority')
  })
  it('default sort is priority ascending, ties by updated newest-first (SPL-1181)', () => {
    assert.deepEqual(DEFAULT_SORT, { col: 'priority', dir: 'asc' })
    // priority wins: 1 at the top, then 2, then 3.
    const l = [mk(1, { priority: 3 }), mk(2, { priority: 1 }), mk(3, { priority: 2 })]
    assert.deepEqual(keys(sortSheet(l)), ['SPL-2', 'SPL-3', 'SPL-1'])
    // equal priority: newest update first (the stable secondary order).
    assert.deepEqual(keys(sortSheet([mk(1), mk(3), mk(2)])), ['SPL-3', 'SPL-2', 'SPL-1'])
  })
  it('each column sorts both ways; empty cells last either way', () => {
    const l = [mk(1, { title: 'b', deadline: '2026-10-02T00:00:00Z', priority: 2 }), mk(2, { title: 'a' }), mk(10, { title: 'c', deadline: '2026-10-01T00:00:00Z', priority: 1 })]
    assert.deepEqual(keys(sortSheet(l, { col: 'title', dir: 'asc' })), ['SPL-2', 'SPL-1', 'SPL-10'])
    assert.deepEqual(keys(sortSheet(l, { col: 'title', dir: 'desc' })), ['SPL-10', 'SPL-1', 'SPL-2'])
    assert.deepEqual(keys(sortSheet(l, { col: 'key', dir: 'asc' })), ['SPL-1', 'SPL-2', 'SPL-10'])
    assert.deepEqual(keys(sortSheet(l, { col: 'deadline', dir: 'asc' })), ['SPL-10', 'SPL-1', 'SPL-2'])
    assert.deepEqual(keys(sortSheet(l, { col: 'deadline', dir: 'desc' })), ['SPL-1', 'SPL-10', 'SPL-2'])
    assert.deepEqual(keys(sortSheet(l, { col: 'priority', dir: 'asc' })), ['SPL-10', 'SPL-1', 'SPL-2'])
  })
  it('status follows the workflow order, assignee and label their shown names', () => {
    const l = [mk(1, { status: 'done', assignee: 'HUM-2' }), mk(2, { status: 'eval', assignee: 'HUM-1', labels: ['z'] }), mk(3, { status: 'wip', labels: ['a'] })]
    assert.deepEqual(keys(sortSheet(l, { col: 'status', dir: 'asc' })), ['SPL-2', 'SPL-3', 'SPL-1'])
    const name = (id) => ({ 'HUM-1': 'Zed', 'HUM-2': 'Amy' })[id]
    assert.deepEqual(keys(sortSheet(l, { col: 'assignee', dir: 'asc' }, { name })), ['SPL-1', 'SPL-2', 'SPL-3'])
    assert.deepEqual(keys(sortSheet(l, { col: 'label', dir: 'asc' })), ['SPL-3', 'SPL-2', 'SPL-1'])
  })
  it('every sheet column is sortable', () => {
    assert.deepEqual(SHEET_COLUMNS, ['key', 'title', 'status', 'priority', 'level', 'assignee', 'label', 'deadline', 'updated'])
  })
})
