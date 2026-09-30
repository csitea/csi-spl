// specs/039 issues-v1: grouping, the hub's sort and filters mirrored in the
// browser, live frames by key, and the deadline <-> datetime-local bridge.
//
// Run: node tests/unit/issues.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { ISSUE_STATUSES, issueQuery, matchIssue, normalizeIssue, sortIssues } from '../../src/utils/issues.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'
import {
  applyIssueFrame, applyLabelFrame, clampIssuePane, deadlineToLocalInput, groupIssues, isOverdue,
  controlLabel, loadIssuePane, localInputToDeadline, saveIssuePane, stepKey, visibleOrder,
} from '../../src/utils/issues-view.mjs'

const mk = (n, extra = {}) => normalizeIssue({ key: `SPL-${n}`, number: n, title: `t${n}`, ...extra })

const list = [
  mk(1, { priority: 2, level: 2, assignee: 'CLE-07', labels: ['bug'], deadline: '2026-10-01T12:30:00Z', updated_at: '2026-09-26T08:00:00Z' }),
  mk(2, { priority: 1, level: 1, assignee: 'HUM-3', status: 'todo', updated_at: '2026-09-26T09:00:00Z' }),
  mk(3, { priority: 0, level: 3, updated_at: '2026-09-26T07:00:00Z' }),
  mk(4, { priority: 4, level: 2, status: 'done', deadline: '2026-09-01T00:00:00Z' }),
]

describe('sortIssues mirrors the hub (hub.SortIssues)', () => {
  const keys = (l) => l.map((i) => i.key)
  it('priority: urgent first, no priority last', () => {
    assert.deepEqual(keys(sortIssues(list)), ['SPL-2', 'SPL-1', 'SPL-4', 'SPL-3'])
  })
  it('level: the top of the tree first (rdb 0056), ties by newest number', () => {
    assert.deepEqual(keys(sortIssues(list, 'level')), ['SPL-2', 'SPL-4', 'SPL-1', 'SPL-3'])
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
    assert.deepEqual(pick({ priority: [5] }), ['SPL-3']) // no priority reads as prio 5 (rdb 0054)
    assert.deepEqual(pick({ level: [1, 3] }), ['SPL-2', 'SPL-3'])
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
    assert.deepEqual(g.map((x) => x.count), [2, 1, 0, 0, 0, 0, 0, 1]) // eval, todo, wip, diss, blocked, onhold, qas, done
    assert.deepEqual(g[0].issues.map((i) => i.key), ['SPL-1', 'SPL-3'])
  })
  it('hideEmpty + filter + sort', () => {
    const g = groupIssues(list, { hideEmpty: true, sort: 'level', filter: { priority: [5, 2] } })
    assert.deepEqual(g.map((x) => [x.status, x.issues.map((i) => i.key)]), [['eval', ['SPL-1', 'SPL-3']]])
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

describe('issue detail pane width', () => {
  it('clamps to the detail range', () => {
    assert.equal(clampIssuePane(100), 280)
    assert.equal(clampIssuePane(900), 720)
    assert.equal(clampIssuePane(450, 500), 450)
    assert.equal(clampIssuePane('nope'), 380)
  })

  it('stores the detail width beside sidebar and topic', () => {
    const store = memoryStore({ 'spool.pane-widths': JSON.stringify({ sidebar: 300, topic: 400 }) })
    assert.equal(saveIssuePane(500, store), true)
    assert.equal(loadIssuePane(store), 500)
    const saved = JSON.parse(store.getItem('spool.pane-widths'))
    assert.equal(saved.sidebar, 300)
    assert.equal(saved.topic, 400)
    assert.equal(saved.issues, 500)
  })
})

describe('SPL-18 epics', async () => {
  const { createMockIssues, issueQuery: q2, matchIssue: m2, normalizeIssue: n2 } = await import('../../src/utils/issues.mjs')
  const { epicProgress } = await import('../../src/utils/issues-view.mjs')
  it('an epic is the reserved label; an issue names its epic', () => {
    assert.equal(n2({ key: 'SPL-1', labels: ['epic'] }).kind, 'epic')
    assert.equal(n2({ key: 'SPL-1', labels: ['epic'], parent: 'SPL-9' }).epic, '')
    const i = n2({ key: 'SPL-2', parent: 'SPL-1' })
    assert.equal(i.kind, 'issue')
    assert.equal(i.epic, 'SPL-1')
    assert.equal(n2({ key: 'SPL-3', kind: 'issue', epic: 'SPL-4' }).epic, 'SPL-4')
  })
  it('kind and epic filter like the hub (case-insensitive keys)', () => {
    const rows = [n2({ key: 'SPL-1', labels: ['epic'] }), n2({ key: 'SPL-2', epic: 'SPL-1' }), n2({ key: 'SPL-3', epic: 'SPL-9' })]
    assert.deepEqual(rows.filter((i) => m2(i, { kind: 'issue' })).map((i) => i.key), ['SPL-2', 'SPL-3'])
    assert.deepEqual(rows.filter((i) => m2(i, { kind: 'epic' })).map((i) => i.key), ['SPL-1'])
    assert.deepEqual(rows.filter((i) => m2(i, { epic: ['spl-1'] })).map((i) => i.key), ['SPL-2'])
    assert.equal(q2({ kind: 'issue', epic: ['SPL-1'] }), 'kind=issue&epic=SPL-1')
  })
  it('progress is done out of the issues not canceled', () => {
    assert.equal(epicProgress({ total: 4, done: 1, canceled: 2 }), 50)
    assert.equal(epicProgress({ total: 1, canceled: 1 }), 0)
    assert.equal(epicProgress({}), 0)
  })
  it('W16 (spec 047): an issue needs no epic, and a lone one takes subtasks', () => {
    const hub = createMockIssues({ me: 'HUM-1', now: () => '2026-09-29T09:00:00Z' })
    const lone = hub.create({ title: 'x' }).issue
    assert.equal(lone.level, 2)
    assert.equal(lone.epic, '')
    const step = hub.create({ title: 'step', parent: lone.key }).issue
    assert.equal(step.kind, 'subtask')
    assert.equal(step.level, 3)
    assert.throws(() => hub.create({ title: 'deeper', parent: step.key }), (e) => e.token === 'bad_epic')
  })
  it('the mock hub keeps the rule and answers the summary', () => {
    const hub = createMockIssues({ me: 'HUM-1', now: () => '2026-09-26T09:00:00Z' })
    const a = hub.create({ title: 'a', epic: 'SPL-1', status: 'done' }).issue
    assert.throws(() => hub.create({ title: 'b', epic: a.key }), (e) => e.token === 'bad_epic')
    const e = hub.create({ title: 'E', kind: 'epic' }).issue
    assert.equal(e.kind, 'epic')
    assert.throws(() => hub.update('SPL-1', { kind: 'issue', epic: e.key }), (x) => x.token === 'epic_has_issues')
    assert.equal(hub.update(a.key, { epic: e.key }).issue.epic, e.key)
    const list = hub.list('kind=issue')
    assert.deepEqual(list.issues.map((i) => i.key), [a.key])
    assert.deepEqual(list.epics.map((x) => [x.key, x.total, x.done]), [['SPL-1', 0, 0], [e.key, 1, 1]])
  })
})

describe('SPL-18 three levels (owner 09:08)', async () => {
  const { createMockIssues, normalizeIssue: n3, isTopKind } = await import('../../src/utils/issues.mjs')
  it('epic and feature are level 1; a subtask names its level-1 epic', () => {
    assert.equal(isTopKind('feature'), true)
    assert.equal(isTopKind('subtask'), false)
    const s = n3({ key: 'SPL-4', kind: 'subtask', parent: 'SPL-3', epic: 'SPL-2' })
    assert.equal(s.kind, 'subtask')
    assert.equal(s.epic, 'SPL-2')
    assert.equal(n3({ key: 'SPL-2', kind: 'feature', parent: 'SPL-9' }).epic, '')
  })
  it('the mock hub builds and guards the tree', () => {
    const hub = createMockIssues({ me: 'HUM-1', now: () => '2026-09-26T09:00:00Z' })
    const f = hub.create({ title: 'F', kind: 'feature' }).issue
    const a = hub.create({ title: 'a', epic: f.key }).issue
    const s = hub.create({ title: 's', parent: a.key }).issue
    assert.deepEqual([f.kind, a.kind, s.kind, s.epic], ['feature', 'issue', 'subtask', f.key])
    assert.throws(() => hub.create({ title: 'x', parent: s.key }), (e) => e.token === 'bad_epic')
    assert.throws(() => hub.create({ title: 'x', epic: a.key }), (e) => e.token === 'bad_epic')
    assert.deepEqual(hub.list(`parent=${a.key}`).issues.map((i) => i.key), [s.key])
    assert.deepEqual(hub.list('kind=issue').issues.map((i) => i.key), [a.key])
    assert.deepEqual(hub.list('').epics.map((e) => [e.key, e.kind, e.total]), [['SPL-1', 'epic', 0], [f.key, 'feature', 1]])
  })
})

describe('the spool-client query copy agrees with issues.mjs (issues-v1 §4)', async () => {
  const { createSpoolClient } = await import('../../src/utils/spool-client.mjs')
  const { issueQuery: q4 } = await import('../../src/utils/issues.mjs')
  it('every filter the Issues page sends reaches the hub', async () => {
    const urls = []
    const fetchFn = async (url) => {
      urls.push(String(url))
      return { ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => ({ issues: [] }), text: async () => '{}' }
    }
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn, token: 'tok' })
    const filter = { kind: 'issue', epic: ['SPL-1'], parent: ['SPL-3'], status: ['todo'], priority: [1], level: [2], assignee: ['me'], label: ['bug'],
      deadlineBefore: '2026-10-01T00:00:00Z', deadlineAfter: '2026-09-01T00:00:00Z' }
    await c.listIssues({ filter, sort: 'level' })
    assert.equal(urls.length, 1)
    assert.equal(new URL(urls[0]).search.slice(1), q4(filter, 'level'))
  })
})

describe('deadline picker: 24-hour, 07:00-22:00 (owner, topic 32a56460)', async () => {
  const { deadlineTimes, joinLocal, splitLocal, DEADLINE_DEFAULT_TIME } = await import('../../src/utils/issues-view.mjs')
  it('offers 07:00 .. 22:00 every 15 minutes, 24-hour, no AM/PM', () => {
    const times = deadlineTimes()
    assert.equal(times[0], '07:00')
    assert.equal(times[times.length - 1], '22:00')
    assert.equal(times.length, (22 - 7) * 4 + 1)
    assert.ok(times.includes('13:45') && !times.includes('06:45') && !times.includes('22:15'))
    assert.ok(times.every((t) => /^\d{2}:\d{2}$/.test(t)))
  })
  it('keeps a stored time outside the window instead of dropping it', () => {
    const times = deadlineTimes('23:30')
    assert.equal(times[times.length - 1], '23:30')
    assert.equal(deadlineTimes('09:15').length, 61)
  })
  it('splits and joins the local value; a date alone gets the default time', () => {
    assert.deepEqual(splitLocal('2026-10-01T15:30'), { date: '2026-10-01', time: '15:30' })
    assert.deepEqual(splitLocal(''), { date: '', time: '' })
    assert.equal(joinLocal('2026-10-01', '21:45'), '2026-10-01T21:45')
    assert.equal(joinLocal('2026-10-01', ''), `2026-10-01T${DEADLINE_DEFAULT_TIME}`)
    assert.equal(joinLocal('', '10:00'), '')
  })
})

describe('the owner statuses and prio 1..5 (rdb 0054, topics f2c32da2 + d81cbf47)', async () => {
  const { ISSUE_STATUSES: S, normalizeStatus, normalizeIssue: n5, createMockIssues, PRIO_DEFAULT } = await import('../../src/utils/issues.mjs')
  const { statusLabel, statusHintKey, ISSUE_PRIORITIES } = await import('../../src/utils/issues-view.mjs')
  it('the eight statuses in the owner order, shown with their numbers (rdb 0061: 05-blocked, 06-onhold)', () => {
    assert.deepEqual(S, ['eval', 'todo', 'wip', 'diss', 'blocked', 'onhold', 'qas', 'done'])
    assert.deepEqual(S.map(statusLabel), ['01-eval', '02-todo', '03-wip', '03-diss', '05-blocked', '06-onhold', '07-qas', '09-done'])
    assert.equal(statusHintKey('wip'), 'issues.status_hint.wip')
    const page = readFileSync(new URL('../../src/pages/issues.vue', import.meta.url), 'utf8')
    assert.match(page, /data-test="issues-filter-status-opt"/)
    assert.match(page, /class="issues-status-tip"/)
    assert.equal(page.includes('<option v-for="s in ISSUE_STATUSES"'), false)
  })
  it('a first-set status still reads as its successor', () => {
    assert.deepEqual(['backlog', 'in_progress', 'in_review', 'canceled', 'todo'].map(normalizeStatus), ['eval', 'wip', 'qas', 'diss', 'todo'])
    assert.equal(n5({ key: 'SPL-1', status: 'in_progress' }).status, 'wip')
  })
  it('prio is a number 1..5, 5 when unset', () => {
    assert.deepEqual(ISSUE_PRIORITIES, [1, 2, 3, 4, 5])
    assert.equal(PRIO_DEFAULT, 5)
    assert.equal(n5({ key: 'SPL-1' }).priority, 5)
    const hub = createMockIssues({ me: 'HUM-1', now: () => '2026-09-26T10:00:00Z' })
    const i = hub.create({ title: 'x', epic: 'SPL-1' }).issue
    assert.deepEqual([i.status, i.priority], ['eval', 5])
    assert.throws(() => hub.update(i.key, { priority: 6 }), (e) => e.token === 'bad_issue')
    assert.equal(hub.update(i.key, { priority: 0 }).issue.priority, 5) // 0 = unset, like the hub
    assert.equal(hub.update(i.key, { status: 'canceled' }).issue.status, 'diss')
  })
})

describe('filter row labels', () => {
  it('names every closed control so no two read the same', () => {
    const row = [
      controlLabel('Sort', 'Level'),
      controlLabel('Status', '02-todo'),
      controlLabel('prio', 'All'),
      controlLabel('Level', 'All'),
      controlLabel('Assignee', 'All'),
      controlLabel('Label', 'All'),
      'Deadline:',
    ]
    assert.equal(new Set(row).size, row.length)
    assert.notEqual(controlLabel('Sort', 'Level'), controlLabel('Level', 'All'))
    assert.notEqual(controlLabel('prio', '1'), controlLabel('Level', '1'))
    assert.equal(controlLabel('Status', '02-todo'), 'Status: 02-todo')
    assert.equal(controlLabel('Sort', 'prio'), 'Sort: prio')
  })

  it('owner, topic e00da93b: a sheet - a names row, then value-only filters under the columns', () => {
    const src = readFileSync(new URL('../../src/pages/issues.vue', import.meta.url), 'utf8')
    const head = src.slice(src.indexOf('data-test="issues-filters"'), src.indexOf('</thead>'))
    const names = head.slice(0, head.indexOf('issues-frow'))
    assert.match(names, /v-for="c in sheetColumns"/)
    assert.match(names, /:aria-sort=/)
    const cols = src.slice(src.indexOf('const sheetColumns = computed'), src.indexOf('])', src.indexOf('const sheetColumns = computed')))
    for (const k of ['issues_view.col_key', 'issues_view.col_title', 'issues.filter_status', 'issues.filter_priority', 'issues.filter_level', 'issues.filter_assignee', 'issues.filter_label', 'issues.field_deadline', 'issues.sort_updated']) {
      assert.ok(cols.includes(`t('${k}')`), k)
    }
    const filters = head.slice(head.indexOf('issues-frow'))
    for (const d of ['issues-filter-status-btn', 'issues-filter-priority', 'issues-filter-level', 'issues-filter-assignee', 'issues-filter-label', 'issues-filter-deadline-date']) {
      assert.ok(filters.includes(d), d)
    }
    assert.equal(head.includes('controlLabel('), false, 'no Name: prefix inside a control')
    assert.equal(/\}\}: \{\{/.test(head), false, 'no Name: prefix inside a control')
    assert.match(src, /data-test="issues-filter-deadline"/)
    assert.equal(src.includes('issues-filter-from'), false)
    assert.equal(src.includes('issues-filter-until'), false)
    assert.equal(src.includes('deadlineAfter'), false)
  })
})

describe('SPL-966: 05-blocked and 06-onhold', async () => {
  const { createMockIssues } = await import('../../src/utils/issues.mjs')
  it('every locale names both on hover, and each has its own glyph and colour', () => {
    for (const f of readdirSync(new URL('../../i18n/locales/', import.meta.url)).filter((x) => x.endsWith('.json'))) {
      const h = JSON.parse(readFileSync(new URL(`../../i18n/locales/${f}`, import.meta.url), 'utf8')).issues.status_hint
      assert.ok(h.blocked && h.onhold, f)
    }
    const page = readFileSync(new URL('../../src/pages/issues.vue', import.meta.url), 'utf8')
    const glyph = readFileSync(new URL('../../src/components/IssueGlyph.vue', import.meta.url), 'utf8')
    assert.match(page, /blocked: 'status-blocked'/)
    assert.match(page, /onhold: 'status-onhold'/)
    assert.match(page, /\.issues-st--blocked \{ color: var\(--color-danger\)/)
    assert.match(glyph, /"status-blocked"/)
    assert.match(glyph, /"status-onhold"/)
  })
  it('the mock lists an issue under 05-blocked and counts it', () => {
    const m = createMockIssues({ me: 'HUM-1' })
    const i = m.create({ title: 'waits', epic: 'SPL-1', status: 'blocked' }).issue
    assert.equal(i.status, 'blocked')
    assert.equal(m.update(i.key, { status: 'onhold' }).issue.status, 'onhold')
    const l = m.list('status=onhold')
    assert.deepEqual(l.issues.map((x) => x.key), [i.key])
    assert.equal(l.counts.onhold, 1)
  })
})

describe('owner, topic e65c0f60: the default view is one flat list', () => {
  it('by none: one group with no status, every kept issue, in the sort order', () => {
    const g = groupIssues(list, { sort: 'updated', by: 'none' })
    assert.equal(g.length, 1)
    assert.equal(g[0].status, '')
    assert.deepEqual(g[0].issues.map((i) => i.key), sortIssues(list, 'updated').map((i) => i.key))
  })
  it('by status (the old view) still groups (CONTROL)', () => {
    assert.ok(groupIssues(list, { sort: 'updated' }).length > 1)
  })
})

describe('SPL-1027: delete (issues-v1 op delete, the mock soft delete)', async () => {
  const { createMockIssues } = await import('../../src/utils/issues.mjs')
  const { applyIssueFrame } = await import('../../src/utils/issues-view.mjs')
  it('an op delete frame drops the row by key; create / update keep merging', () => {
    const list = [{ key: 'SPL-2', title: 'a' }, { key: 'SPL-3', title: 'b' }]
    assert.deepEqual(applyIssueFrame(list, { type: 'issue', op: 'delete', issue: { key: 'SPL-2' } }).map((i) => i.key), ['SPL-3'])
    assert.equal(applyIssueFrame(list, { type: 'issue', op: 'update', issue: { key: 'SPL-2', title: 'x' } }).length, 2)
  })
  it('the mock refuses a parent with a live child, then deletes; a deleted issue reads 404', () => {
    const m = createMockIssues({ me: 'HUM-1' })
    const parent = m.create({ title: 'parent', epic: 'SPL-1' }).issue
    const child = m.create({ title: 'child', parent: parent.key }).issue
    assert.throws(() => m.remove(parent.key), (e) => e.token === 'issue_has_children' && e.status === 409)
    assert.equal(m.remove(child.key).issue.key, child.key)
    assert.throws(() => m.get(child.key), (e) => e.status === 404)
    assert.equal(m.remove(parent.key).issue.key, parent.key)
    assert.equal(m.list('kind=issue').issues.some((i) => i.key === parent.key), false)
  })
  it('the page asks with UiConfirm and the client sends DELETE', () => {
    const page = readFileSync(new URL('../../src/pages/issues.vue', import.meta.url), 'utf8')
    const client = readFileSync(new URL('../../src/utils/spool-client.mjs', import.meta.url), 'utf8')
    assert.match(page, /<UiConfirm[\s\S]*?testid="issues-delete"/)
    assert.match(page, /api\.deleteIssue\(issue\.key\)/)
    assert.match(client, /async deleteIssue\(ref[^)]*\) \{[\s\S]*?method: 'DELETE'/)
  })
  it('SPL-1226: cascade archive/delete client + mock', () => {
    const client = readFileSync(new URL('../../src/utils/spool-client.mjs', import.meta.url), 'utf8')
    // the client passes ?cascade=1 through to the hub on both verbs
    assert.match(client, /async deleteIssue\(ref, \{ cascade = false \} = \{\}\)/)
    assert.match(client, /async archiveIssue\(ref, \{ cascade = false \} = \{\}\)[\s\S]*?\/archive/)
    const m = createMockIssues({ me: 'HUM-1' })
    const epic = m.create({ title: 'Epic', kind: 'epic' }).issue
    const child = m.create({ title: 'Child', epic: epic.key }).issue
    const sub = m.create({ title: 'Sub', parent: child.key }).issue
    // without cascade a parent with a child is refused
    assert.throws(() => m.remove(epic.key), (e) => e.status === 409 && e.token === 'issue_has_children')
    // cascade delete takes the whole subtree and names the descendants
    const res = m.remove(epic.key, true)
    assert.equal(res.issue.key, epic.key)
    assert.equal(res.descendants.length, 2)
    assert.ok(res.descendants.includes(child.key) && res.descendants.includes(sub.key))
    assert.equal(m.list().issues.some((i) => [epic.key, child.key, sub.key].includes(i.key)), false)
    // archive cascades the same way
    const e2 = m.create({ title: 'Epic2', kind: 'epic' }).issue
    m.create({ title: 'C2', epic: e2.key })
    assert.equal(m.archive(e2.key, true).descendants.length, 1)
    assert.equal(m.list().issues.some((i) => i.key === e2.key), false)
  })
})
