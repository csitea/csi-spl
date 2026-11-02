// SPL-4648 (owner, t1 e04820a5): the Issues list's state, read from and written
// to its URL. A value the URL names that cannot be used reads as not named.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { importTs } from './lib/load-ts.mjs'

const { LIST_PARAMS, listStateFromQuery, listStateQuery, sameQuery } = await importTs('src/utils/issues-list-url.ts')

const FULL = { view: 'status', sort: 'title', dir: 'desc', unread: '1', status: 'wip', priority: '2', level: '3', assignee: 'HUM-2', label: 'bug', deadline: '2026-12-02T12:00', fold: 'eval,done' }

describe('the Issues list URL', () => {
  it('reads every parameter and writes the same query back', () => {
    const s = listStateFromQuery(FULL, 'HUM-1')
    assert.deepEqual(s, { view: 'status', sort: { col: 'title', dir: 'desc' }, unread: true, status: 'wip', priority: '2', level: '3', assignee: 'HUM-2', label: 'bug', deadline: '2026-12-02T12:00', fold: ['eval', 'done'] })
    assert.deepEqual(listStateQuery(s, {}, 'HUM-1'), FULL)
  })
  it('names every parameter it owns', () => {
    assert.deepEqual([...LIST_PARAMS].sort(), Object.keys(FULL).sort())
  })
  it('CONTROL: a bad value reads as not named, and nothing throws', () => {
    const s = listStateFromQuery({ view: 'grid', sort: 'nope', dir: 'up', unread: 'yes', status: 'nope', priority: '9', level: 'x', deadline: '2026-13-45T99:99' })
    assert.deepEqual(s, { view: '', sort: { col: '', dir: '' }, unread: false, status: '', priority: '', level: '', assignee: '', label: '', deadline: '', fold: null })
    assert.deepEqual(listStateQuery(s), {})
  })
  it('a date that does not exist is not a deadline', () => {
    assert.equal(listStateFromQuery({ deadline: '2026-02-30T10:00' }).deadline, '')
    assert.equal(listStateFromQuery({ deadline: '2026-02-28T10:00' }).deadline, '2026-02-28T10:00')
  })
  it('fold keeps only statuses; an empty one is named and folds nothing', () => {
    assert.deepEqual(listStateFromQuery({ fold: 'zz,wip' }).fold, ['wip'])
    assert.deepEqual(listStateFromQuery({ fold: '' }).fold, [])
    assert.equal(listStateFromQuery({}).fold, null)
  })
  it('"me" travels as the id, so a pasted link names the same person', () => {
    assert.equal(listStateQuery({ assignee: 'me' }, {}, 'HUM-1').assignee, 'HUM-1')
    assert.equal(listStateFromQuery({ assignee: 'HUM-1' }, 'HUM-1').assignee, 'me')
    assert.equal(listStateFromQuery({ assignee: 'HUM-1' }, 'HUM-2').assignee, 'HUM-1')
    assert.equal(listStateQuery({ assignee: 'me' }).assignee, 'me')
  })
  it('keeps what it does not own, and drops what the state no longer names', () => {
    assert.deepEqual(listStateQuery({ view: 'list' }, { epic: 'SPL-1', issue: 'SPL-2', status: 'wip', x: 'y' }), { epic: 'SPL-1', issue: 'SPL-2', x: 'y', view: 'list' })
  })
  it('compares queries whatever their order', () => {
    assert.equal(sameQuery({ a: '1', b: '2' }, { b: '2', a: '1' }), true)
    assert.equal(sameQuery({ a: '1' }, { a: '1', b: '2' }), false)
  })
})
