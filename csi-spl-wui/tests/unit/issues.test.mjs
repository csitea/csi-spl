// specs/039 issues-v1: grouping, the hub's sort and filters mirrored in the
// browser, live frames by key, and the deadline <-> datetime-local bridge.
//
// Run: node tests/unit/issues.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { ISSUE_STATUSES, issueQuery, matchIssue, normalizeIssue, sortIssues } from '../../src/utils/issues.mjs'
import {
  applyIssueFrame, applyLabelFrame, deadlineToLocalInput, groupIssues, isOverdue,
  localInputToDeadline, stepKey, visibleOrder,
} from '../../src/utils/issues-view.mjs'

const mk = (n, extra = {}) => normalizeIssue({ key: `SPL-${n}`, number: n, title: `t${n}`, ...extra })

const list = [
  mk(1, { priority: 2, level: 3, assignee: 'CLE-07', labels: ['bug'], deadline: '2026-10-01T12:30:00Z', updated_at: '2026-09-26T08:00:00Z' }),
  mk(2, { priority: 1, level: 1, assignee: 'HUM-3', status: 'todo', updated_at: '2026-09-26T09:00:00Z' }),
  mk(3, { priority: 0, level: 5, updated_at: '2026-09-26T07:00:00Z' }),
  mk(4, { priority: 4, status: 'done', deadline: '2026-09-01T00:00:00Z' }),
]

describe('sortIssues mirrors the hub (hub.SortIssues)', () => {
  const keys = (l) => l.map((i) => i.key)
  it('priority: urgent first, no priority last', () => {
    assert.deepEqual(keys(sortIssues(list)), ['SPL-2', 'SPL-1', 'SPL-4', 'SPL-3'])
  })
  it('level: largest first, ties by newest number', () => {
    assert.deepEqual(keys(sortIssues(list, 'level')), ['SPL-3', 'SPL-1', 'SPL-2', 'SPL-4'])
  })
  it('deadline: soonest first, none last', () => {
    assert.deepEqual(keys(sortIssues(list, 'deadline')), ['SPL-4', 'SPL-1', 'SPL-3', 'SPL-2'])
  })
  it('updated: newest first', () => {
    assert.deepEqual(keys(sortIssues(list, 'updated')).slice(0, 3), ['SPL-2', 'SPL-1', 'SPL-3'])
  })
  it('does not mutate its input', () => {
    const before = keys(list)
    sortIssues(list, 'level')
    assert.deepEqual(keys(list), before)
  })
})

describe('matchIssue filters on every attribute', () => {
  const pick = (f, me) => list.filter((i) => matchIssue(i, f, me)).map((i) => i.key)
  it('status / priority / level / label', () => {
    assert.deepEqual(pick({ status: ['todo'] }), ['SPL-2'])
    assert.deepEqual(pick({ priority: [0] }), ['SPL-3'])
    assert.deepEqual(pick({ level: [1, 3] }), ['SPL-1', 'SPL-2'])
    assert.deepEqual(pick({ label: ['bug'] }), ['SPL-1'])
  })
  it('assignee me / none / an id', () => {
    assert.deepEqual(pick({ assignee: ['me'] }, 'HUM-3'), ['SPL-2'])
    assert.deepEqual(pick({ assignee: ['none'] }), ['SPL-3', 'SPL-4'])
    assert.deepEqual(pick({ assignee: ['CLE-07', 'none'] }), ['SPL-1', 'SPL-3', 'SPL-4'])
  })
  it('deadline range: no deadline never matches', () => {
    assert.deepEqual(pick({ deadlineBefore: '2026-09-30T00:00:00Z' }), ['SPL-4'])
    assert.deepEqual(pick({ deadlineAfter: '2026-09-30T00:00:00Z' }), ['SPL-1'])
  })
})

describe('groupIssues: one group per status, workflow order, counts', () => {
  it('keeps empty groups by default, in Linear order', () => {
    const g = groupIssues(list)
    assert.deepEqual(g.map((x) => x.status), ISSUE_STATUSES)
    assert.deepEqual(g.map((x) => x.count), [2, 1, 0, 0, 1, 0])
    assert.deepEqual(g[0].issues.map((i) => i.key), ['SPL-1', 'SPL-3'])
  })
  it('hideEmpty + filter + sort', () => {
    const g = groupIssues(list, { hideEmpty: true, sort: 'level', filter: { priority: [0, 2] } })
    assert.deepEqual(g.map((x) => [x.status, x.issues.map((i) => i.key)]), [['backlog', ['SPL-3', 'SPL-1']]])
  })
  it('J / K walk the visible rows, collapsed groups skipped', () => {
    const order = visibleOrder(groupIssues(list), { todo: true })
    assert.deepEqual(order.map((i) => i.key), ['SPL-1', 'SPL-3', 'SPL-4'])
    assert.equal(stepKey(order, '', 1), 'SPL-1')
    assert.equal(stepKey(order, '', -1), 'SPL-4')
    assert.equal(stepKey(order, 'SPL-3', 1), 'SPL-4')
    assert.equal(stepKey(order, 'SPL-4', 1), 'SPL-4')
    assert.equal(stepKey(order, 'SPL-1', -1), 'SPL-1')
    assert.equal(stepKey([], 'x', 1), '')
  })
})

describe('live frames', () => {
  it('create appends, update replaces by key, a stale update is ignored', () => {
    let l = applyIssueFrame(list, { type: 'issue', op: 'create', issue: { key: 'SPL-5', number: 5, title: 'new' } })
    assert.equal(l.length, 5)
    l = applyIssueFrame(l, { type: 'issue', op: 'update', issue: { ...list[0], status: 'done', updated_at: '2026-09-26T10:00:00Z' } })
    assert.equal(l.find((i) => i.key === 'SPL-1').status, 'done')
    l = applyIssueFrame(l, { type: 'issue', op: 'update', issue: { ...list[0], status: 'todo', updated_at: '2026-09-26T01:00:00Z' } })
    assert.equal(l.find((i) => i.key === 'SPL-1').status, 'done')
    assert.equal(applyIssueFrame(l, { type: 'message' }), l)
  })
  it('labels: added once, sorted by name', () => {
    let ls = applyLabelFrame([{ id: 'ux', name: 'UX', color: '#000000' }], { type: 'issue_label', label: { id: 'bug', name: 'Bug', color: '#ff0000' } })
    assert.deepEqual(ls.map((l) => l.id), ['bug', 'ux'])
    ls = applyLabelFrame(ls, { type: 'issue_label', label: { id: 'bug', name: 'Bug' } })
    assert.equal(ls.length, 2)
  })
})

describe('deadline: calendar + time in local time, stored UTC', () => {
  it('round-trips through datetime-local at a fixed offset', () => {
    assert.equal(deadlineToLocalInput('2026-10-01T12:30:00Z', 180), '2026-10-01T15:30')
    assert.equal(localInputToDeadline('2026-10-01T15:30', 180), '2026-10-01T12:30:00Z')
    assert.equal(localInputToDeadline('2026-10-01T00:15', -300), '2026-10-01T05:15:00Z')
  })
  it('clears and refuses', () => {
    assert.equal(deadlineToLocalInput(''), '')
    assert.equal(localInputToDeadline(''), '')
    assert.equal(localInputToDeadline('tomorrow'), null)
  })
  it('overdue only while open', () => {
    const now = Date.parse('2026-09-26T00:00:00Z')
    assert.equal(isOverdue(list[3], now), false) // done
    assert.equal(isOverdue({ ...list[3], status: 'todo' }, now), true)
    assert.equal(isOverdue(list[0], now), false)
  })
})

describe('issueQuery is the hub query (issues-v1 §4)', () => {
  it('only what is set; priority is the default sort', () => {
    assert.equal(issueQuery({}, 'priority'), '')
    assert.equal(issueQuery({ status: ['todo', 'in_progress'], assignee: ['me'], deadlineBefore: '2026-10-01T00:00:00Z' }, 'level'),
      'status=todo%2Cin_progress&assignee=me&deadline_before=2026-10-01T00%3A00%3A00Z&sort=level')
  })
})
