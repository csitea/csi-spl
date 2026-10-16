/**
 * Issues, the way Linear keeps them (specs/039, contracts/issues-v1.md).
 * Pure helpers the issues store and the Issues pages share: the workflow
 * order, the priority and level scales, grouping, the hub's sort and filters
 * mirrored client side (so a live frame lands in the right place without a
 * refetch), frame application and the deadline <-> datetime-local bridge.
 */

import { ISSUE_CHANNEL } from './parent-section.mjs'
import { isAiMessage } from './typed-by.mjs'
import { MOCK_DEFAULT_TOPIC, MOCK_GONE_TOPIC, mockCreateDiscussions, mockFullDiscussions, mockLinkDiscussion, mockUnlinkDiscussion, normalizeDiscussions } from './issue-discussions.mjs'
/** issues-v1 §8: the tree's kinds. Level 1 = epic | feature. */
export const ISSUE_KINDS = ['epic', 'feature', 'issue', 'subtask']
export const isTopKind = (k) => k === 'epic' || k === 'feature'

/** The owner's statuses in list order (rdb 0054, topic f2c32da2; rdb 0061,
 *  SPL-966): shown as 01-eval, 02-todo, 03-wip, 03-diss, 05-blocked,
 *  06-onhold, 07-qas, 09-done (issues-v1 §2). */
export const ISSUE_STATUSES = ['eval', 'todo', 'wip', 'diss', 'blocked', 'onhold', 'qas', 'done']
/** a first-set status (before rdb 0054) -> its successor */
const LEGACY_STATUS = { backlog: 'eval', in_progress: 'wip', in_review: 'qas', canceled: 'diss' }
export const normalizeStatus = (s) => LEGACY_STATUS[s] || s
/** prio (rdb 0054, topic d81cbf47): 1 highest .. 5 lowest, 5 for a new issue */
export const PRIO_DEFAULT = 5

/** One issue as the hub sent it, with every field present and typed. */
export function normalizeIssue(raw) {
  const r = raw || {}
  const labels = Array.isArray(r.labels) ? r.labels.map(String) : []
  /* SPL-18 (rdb 0053): epic | feature (level 1), issue (level 2), subtask
     (level 3); an older hub marked an epic with the `epic` label only */
  const kind = ISSUE_KINDS.includes(r.kind) ? r.kind : labels.includes('epic') ? 'epic' : 'issue'
  const top = kind === 'epic' || kind === 'feature'
  return {
    kind,
    epic: top ? '' : String(r.epic || (kind === 'issue' ? r.parent : '') || ''),
    key: String(r.key || ''),
    number: Number(r.number) || 0,
    title: String(r.title || ''),
    description: String(r.description || ''),
    status: ISSUE_STATUSES.includes(normalizeStatus(r.status)) ? normalizeStatus(r.status) : 'eval',
    priority: Number(r.priority) || PRIO_DEFAULT,
    level: Number(r.level) || 0,
    assignee: String(r.assignee || ''),
    labels,
    deadline: String(r.deadline || ''),
    parent: String(r.parent || ''),
    task_id: String(r.task_id || ''),
    channel: String(r.channel || ISSUE_CHANNEL),
    created_by: String(r.created_by || ''),
    created_at: String(r.created_at || ''),
    updated_by: String(r.updated_by || ''),
    updated_at: String(r.updated_at || ''),
    completed_at: String(r.completed_at || ''),
    canceled_at: String(r.canceled_at || ''),
    /* SPL-1559 (rdb 0184): the viewer has not opened it yet (the hub's
       per-viewer mark on a list or single read; a live frame has none) */
    unopened: r.unopened === true,
    /* SPL-1593 (rdb 0194): the discussions it links, at least one on the hub;
       a list read carries the links, a single read their state and title */
    discussions: normalizeDiscussions(r.discussions),
  }
}

/**
 * SPL-1559: the hub's rule for an issue that can be new to `me` (hub
 * issue_opens.go issueUnopened, less the opened set): still to do, not a
 * level-1 row, assigned to me and created by someone else.
 */
export function unopenedCandidate(issue, me) {
  const i = issue || {}
  return !!me && i.assignee === me && i.created_by !== me && !isTopKind(i.kind) && i.status !== 'done' && i.status !== 'diss'
}

export function normalizeLabel(raw) {
  const r = raw || {}
  return { id: String(r.id || ''), name: String(r.name || r.id || ''), color: String(r.color || '#6b7280') }
}

const prioRank = (p) => Number(p) || PRIO_DEFAULT
const ms = (s) => {
  const t = Date.parse(String(s || ''))
  return Number.isFinite(t) ? t : NaN
}

/**
 * The hub's order (hub.SortIssues): priority urgent first and none last;
 * level top of the tree first (1 epic / feature, 2 issue, 3 subtask); deadline soonest first and none last; updated /
 * created newest first. Ties: the newest number first. Returns a new array.
 */
export function sortIssues(list, by = 'priority') {
  const out = (list || []).slice()
  out.sort((x, y) => {
    let c = 0
    switch (by || 'priority') {
      case 'priority':
        c = prioRank(x.priority) - prioRank(y.priority)
        break
      case 'level':
        c = (Number(x.level) || 0) - (Number(y.level) || 0)
        break
      case 'deadline': {
        const a = ms(x.deadline)
        const b = ms(y.deadline)
        if (Number.isNaN(a) && !Number.isNaN(b)) c = 1
        else if (!Number.isNaN(a) && Number.isNaN(b)) c = -1
        else if (!Number.isNaN(a)) c = a - b
        break
      }
      case 'updated':
        c = (ms(y.updated_at) || 0) - (ms(x.updated_at) || 0)
        break
      case 'created':
        c = (ms(y.created_at) || 0) - (ms(x.created_at) || 0)
        break
    }
    return c !== 0 ? c : (Number(y.number) || 0) - (Number(x.number) || 0)
  })
  return out
}

/** The direction a hub sort runs without ?dir= (hub issueSortDir). */
const HUB_SORT_DIR = { priority: 'asc', level: 'asc', deadline: 'asc', updated: 'desc', created: 'desc', number: 'desc',
  title: 'asc', status: 'asc', assignee: 'asc', label: 'asc', default: 'asc' }

/* one row's value in a hub sort column; '' is empty and sorts last either way */
function hubCell(i, by) {
  switch (by) {
    case 'priority': case 'default': return Number(i.priority) || ''
    case 'level': return Number(i.level) || ''
    case 'deadline': return Number.isNaN(ms(i.deadline)) ? '' : ms(i.deadline)
    case 'updated': return ms(i.updated_at) || 0
    case 'created': return ms(i.created_at) || 0
    case 'number': return Number(i.number) || 0
    case 'title': return { s: String(i.title || '').toLowerCase() }
    case 'status': return ISSUE_STATUSES.indexOf(i.status)
    case 'assignee': return i.assignee ? { s: i.assignee } : ''
    case 'label': return (i.labels || []).length ? { s: (i.labels || []).slice().sort()[0] } : ''
  }
  return 0
}

/**
 * The hub's paged order (hub issueLess, issues_page.go): the column in its
 * direction, empty last; "default" then updated newest first; then the
 * newest number. Returns a new array.
 */
export function orderIssues(list, by = 'priority', dir = '') {
  const sign = (dir || HUB_SORT_DIR[by] || 'asc') === 'desc' ? -1 : 1
  const cmp = (a, b) => {
    if (a === '' || b === '') return a === b ? 0 : a === '' ? 1 : -1
    if (typeof a === 'object') return (a.s < b.s ? -1 : a.s > b.s ? 1 : 0) * sign
    return (a - b) * sign
  }
  return (list || []).slice().sort((x, y) => {
    const c = cmp(hubCell(x, by), hubCell(y, by))
    if (c) return c
    if (by === 'default') {
      const u = (ms(y.updated_at) || 0) - (ms(x.updated_at) || 0)
      if (u) return u
    }
    return (Number(y.number) || 0) - (Number(x.number) || 0)
  })
}

/**
 * Filters on every attribute (issues-v1 §4). Each set is any-of; an empty
 * set matches everything. assignee accepts 'me' (with `me`) and 'none'.
 * deadlineBefore / deadlineAfter are ISO strings; an issue with no deadline
 * never matches either.
 * @param {ReturnType<typeof normalizeIssue>} issue
 * kind is 'epic' | 'issue'; epic keeps the issues of those epics.
 * @param {{ kind?: string, epic?: string[], status?: string[], priority?: number[], level?: number[], assignee?: string[], label?: string[], deadlineBefore?: string, deadlineAfter?: string }} f
 * @param {string} [me]
 */
export function matchIssue(issue, f = {}, me = '') {
  const has = (a) => Array.isArray(a) && a.length > 0
  if (f.kind && !String(f.kind).split(',').includes(issue.kind)) return false
  if (has(f.parent) && !f.parent.map((e) => String(e).toUpperCase()).includes(issue.parent.toUpperCase())) return false
  if (has(f.epic) && (issue.kind === 'epic' || !f.epic.map((e) => String(e).toUpperCase()).includes(issue.epic.toUpperCase()))) return false
  if (has(f.status) && !f.status.includes(issue.status)) return false
  if (has(f.priority) && !f.priority.map(Number).includes(Number(issue.priority))) return false
  if (has(f.level) && !f.level.map(Number).includes(Number(issue.level))) return false
  if (has(f.assignee)) {
    const want = f.assignee.map((a) => (a === 'me' ? me : a === 'none' ? '' : a))
    if (!want.includes(issue.assignee)) return false
  }
  if (has(f.label) && !issue.labels.some((l) => f.label.includes(l))) return false
  const d = ms(issue.deadline)
  if (f.deadlineBefore && (Number.isNaN(d) || !(d < ms(f.deadlineBefore)))) return false
  if (f.deadlineAfter && (Number.isNaN(d) || d < ms(f.deadlineAfter))) return false
  return true
}

/**
 * The URL query the hub reads (issues-v1 §4) for a filter + sort, and a
 * page (t1 d5d00918): `dir`, `limit` and the `cursor` of the page before.
 */
export function issueQuery(filter = {}, sort = '', page = {}) {
  const q = new URLSearchParams()
  if (filter.kind) q.set('kind', filter.kind)
  for (const k of ['epic', 'parent', 'status', 'priority', 'level', 'assignee', 'label']) {
    const v = filter[k]
    if (Array.isArray(v) && v.length) q.set(k, v.join(','))
  }
  if (filter.deadlineBefore) q.set('deadline_before', filter.deadlineBefore)
  if (filter.deadlineAfter) q.set('deadline_after', filter.deadlineAfter)
  if (sort && sort !== 'priority') q.set('sort', sort)
  if (page.dir) q.set('dir', page.dir)
  if (page.limit) q.set('limit', String(page.limit))
  if (page.cursor) q.set('cursor', page.cursor)
  return q.toString()
}

function mockErr(status, token) {
  return Object.assign(new Error(`spool ${status} ${token}`), { status, token })
}

/* The mock hub's steps (createMockIssues below). Each one takes the tab's
   current `issues` (and `labels`, `now`) so the factory stays a thin shell. */

/** The issue a ref names (`SPL-7` or `7`), or undefined. */
function mockFind(issues, ref) {
  const n = Number(String(ref || '').replace(/^[A-Za-z][A-Za-z0-9]*-/, ''))
  return issues.find((i) => i.number === n)
}

/* SPL-1226: the keys of every descendant of key (its children, then theirs). */
function mockSubtree(issues, key) {
  const out = []
  const queue = [key]
  while (queue.length) {
    const p = queue.shift()
    for (const c of issues) {
      if (c.parent === p) { out.push(c.key); queue.push(c.key) }
    }
  }
  return out
}

/** Issue i with patch b applied by `by`, stamped by `now`. */
function mockApplyPatch(i, b, by, now) {
  const out = { ...i }
  for (const k of ['title', 'description', 'status', 'priority', 'assignee', 'labels', 'deadline']) {
    if (b[k] !== undefined && b[k] !== null) out[k] = k === 'labels' ? b[k].slice() : b[k]
  }
  if (b.epic !== undefined || b.parent !== undefined) out.parent = String(b.epic ?? b.parent ?? '')
  if (b.kind === 'epic' || b.kind === 'feature' || b.kind === 'issue') {
    out.kind = b.kind
    if (isTopKind(b.kind)) out.parent = ''
  }
  out.status = normalizeStatus(out.status)
  if (out.status !== i.status) {
    out.completed_at = out.status === 'done' ? now() : ''
    out.canceled_at = out.status === 'diss' ? now() : ''
  }
  out.updated_by = by
  out.updated_at = now()
  return out
}

/** The hub's checks on a row about to be stored; throws its error. */
function mockCheck(issues, labels, i) {
  if (!String(i.title || '').trim()) throw mockErr(400, 'bad_issue')
  if (!ISSUE_STATUSES.includes(i.status)) throw mockErr(400, 'bad_issue')
  if (!(i.priority >= 1 && i.priority <= 5)) throw mockErr(400, 'bad_issue')
  if (i.labels.some((l) => !labels.some((x) => x.id === l))) throw mockErr(400, 'unknown_label')
  const kids = issues.some((x) => x.parent && x.parent === i.key)
  if (isTopKind(i.kind)) {
    if (i.parent) throw mockErr(400, 'bad_epic')
    return
  }
  const was = mockFind(issues, i.key)
  if (was && isTopKind(was.kind) && kids) throw mockErr(409, 'epic_has_issues')
  if (!i.parent) return /* W16: a lone level-2 issue */
  const parent = mockFind(issues, i.parent)
  if (!parent) throw mockErr(400, 'unknown_parent')
  if (isTopKind(parent.kind)) return
  /* a subtask: its parent is level 2, under a level-1 row or under none */
  const grand = parent.parent ? mockFind(issues, parent.parent) : null
  if ((parent.parent && (!grand || !isTopKind(grand.kind))) || kids) throw mockErr(400, 'bad_epic')
}

/* hub checkEpicField: `epic` names a level-1 row; `parent` also takes a level-2 issue */
function mockEpicField(issues, b) {
  if (!b || !b.epic) return
  const e = mockFind(issues, b.epic)
  if (e && !isTopKind(e.kind)) throw mockErr(400, 'bad_epic')
}

/* the stored row -> what the hub answers: kind subtask, the level-1 key and
   the tree's level (rdb 0056: 1 epic / feature, 2 issue, 3 subtask) */
function mockView(issues, i) {
  if (isTopKind(i.kind)) return { ...i, epic: '', level: 1 }
  const p = mockFind(issues, i.parent)
  if (p && !isTopKind(p.kind)) return { ...i, kind: 'subtask', epic: p.parent || '', level: 3 }
  return { ...i, kind: 'issue', epic: i.parent, level: 2 }
}

/* hub setLevel: a level in the body is only checked against the tree's */
function mockLevelField(issues, b, i, create) {
  const lv = b ? b.level : undefined
  if (lv === undefined || lv === null || (create && lv === 0)) return
  if (!(lv >= 1 && lv <= 3) || lv !== mockView(issues, i).level) throw mockErr(400, 'bad_issue')
}

/** Each level-1 row with the status counts of its level-2 issues. */
function mockSummaries(issues) {
  return issues.filter((e) => isTopKind(e.kind)).map((e) => {
    const mine = issues.filter((i) => !isTopKind(i.kind) && i.parent === e.key)
    const counts = Object.fromEntries(ISSUE_STATUSES.map((st) => [st, mine.filter((i) => i.status === st).length]))
    return { key: e.key, kind: e.kind, number: e.number, title: e.title, status: e.status, total: mine.length, done: counts.done, canceled: counts.diss, counts }
  })
}

/** The filter matchIssue reads, from the hub's list query (issueQuery's inverse). */
function mockFilterOf(q) {
  const csv = (k) => (q.get(k) ? q.get(k).split(',') : [])
  return { kind: q.get('kind') || '', epic: csv('epic'), parent: csv('parent'), status: csv('status'), priority: csv('priority').map(Number), level: csv('level').map(Number),
    assignee: csv('assignee'), label: csv('label'), deadlineBefore: q.get('deadline_before') || '', deadlineAfter: q.get('deadline_after') || '' }
}

/* The mock hub's page (hub issues_page.go): the hub's order, the rows after
   the cursor (here the last row's key), `limit` of them. No limit = all. */
function mockPage(matched, q) {
  const ordered = orderIssues(matched, q.get('sort') || 'priority', q.get('dir') || '')
  const at = q.get('cursor') ? ordered.findIndex((i) => i.key === q.get('cursor')) + 1 : 0
  const limit = Number(q.get('limit')) || 0
  const rows = limit ? ordered.slice(at, at + limit) : ordered.slice(at)
  return { rows, next: limit && at + limit < ordered.length ? rows[rows.length - 1].key : '' }
}

/** A new row numbered n from a create body, before the hub's checks. */
function mockNewIssue(body, n, me, at) {
  const lbl = Array.isArray(body.labels) ? body.labels : []
  const kind = isTopKind(body.kind) ? body.kind : lbl.includes('epic') ? 'epic' : 'issue'
  return normalizeIssue({ status: 'eval', ...body, kind, labels: lbl, parent: isTopKind(kind) ? '' : (body.epic || body.parent || ''), key: `SPL-${n}`, number: n,
    task_id: `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`, channel: ISSUE_CHANNEL,
    created_by: me, created_at: at, updated_by: me, updated_at: at })
}

/** localStorage key: how many issues the mock tenant starts with beyond SPL-1. */
/* rdb 0181: the fields an issue's History tab names, in the hub trigger's order */
const HISTORY_FIELDS = ['title', 'description', 'status', 'priority', 'level', 'assignee', 'kind', 'parent', 'deadline', 'labels']

/** The mock twin of the rdb 0181 trigger: one `changed` event per field that moved. */
function mockChanges(was, now) {
  const out = []
  for (const f of HISTORY_FIELDS) {
    const o = Array.isArray(was[f]) ? was[f].join(',') : String(was[f] ?? '')
    const n = Array.isArray(now[f]) ? now[f].join(',') : String(now[f] ?? '')
    if (o === n) continue
    const desc = f === 'description'
    out.push({ at: now.updated_at, actor: now.updated_by, event: 'changed', field: f, old: desc || o === '' ? null : o, new: desc || n === '' ? null : n })
  }
  return out
}

/** The mock's per-issue history log (rdb 0181), seeded with each issue's created event. */
function mockHistoryLog(issues) {
  const created = (i) => ({ at: i.created_at, actor: i.created_by, event: 'created', old: null, new: null })
  const events = new Map(issues.map((i) => [i.key, [created(i)]]))
  const record = (key, evs) => events.set(key, [...(events.get(key) || []), ...evs])
  return {
    created: (i) => record(i.key, [created(i)]),
    changed: (was, now) => record(now.key, mockChanges(was, now)),
    read: (key) => (events.get(key) || []).map((e) => ({ ...e })),
  }
}

/** issues-v1 history (rdb 0181) of a live issue; 404 for none. */
function mockHistoryOf(i, log) {
  if (!i) throw mockErr(404, 'not_found')
  return { key: i.key, events: log.read(i.key) }
}

export const MOCK_ISSUES_SEED_KEY = 'spool.mock.issues-seed'
/** localStorage key (SPL-1559): how many issues a teammate assigned to me the mock tenant starts with, none opened. */
export const MOCK_ISSUES_NEW_KEY = 'spool.mock.issues-new'
/** the teammate the mock's new issues come from */
const MOCK_TEAMMATE = 'HUM-2'
/** localStorage key (SPL-2120): how many issues an AI agent filed the mock tenant starts with. */
export const MOCK_ISSUES_AGENT_KEY = 'spool.mock.issues-agent'
/** the agent the mock's agent-filed issues come from */
const MOCK_AGENT = 'c-007'

/**
 * SPL-2120 (owner HUM-10, t1 28559e83): an issue an AI agent filed carries
 * the agent bar in the list. The same rule as a message's (HUM-24), read
 * on the issue's creator.
 * @param {{ created_by?: string } | null | undefined} issue
 * @returns {boolean}
 */
export function issueByAgent(issue) {
  return isAiMessage({ from: issue ? issue.created_by : '' })
}

/** a localStorage count, 0..max; 0 without storage */
function mockStoredCount(key, max) {
  try { return Math.min(max, Number(globalThis.localStorage?.getItem(key)) || 0) } catch { return 0 }
}

/** The mock tenant's first issues, numbered from 1 with no gap. */
function mockSeedIssues(me, now) {
  const issues = [normalizeIssue({ key: 'SPL-1', number: 1, title: 'random', kind: 'epic', labels: ['epic'], status: 'in_progress',
    task_id: '00000000-0000-4000-8000-000000000001', created_by: me, updated_by: me, created_at: now(), updated_at: now(),
    /* SPL-1593: a live topic of the mock feed and one that was deleted */
    discussions: [{ task_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', linked_by: me }, { task_id: MOCK_GONE_TOPIC, linked_by: me }] })]
  /* t1 d5d00918: localStorage `spool.mock.issues-seed` = N plays a tenant
     with N more issues (SPL-2 ..), so a test reaches a second page */
  const seed = mockStoredCount(MOCK_ISSUES_SEED_KEY, 500)
  for (let k = 1; k <= seed; k++) {
    issues.push(mockNewIssue({ title: `mock issue ${k}`, description: `mock issue ${k} text`, priority: 1 + (k % 5), discussions: [{ task_id: MOCK_DEFAULT_TOPIC }] }, issues.length + 1, me, now()))
  }
  /* SPL-1559: `spool.mock.issues-new` = N issues a teammate assigned to me, none opened */
  const fresh = mockStoredCount(MOCK_ISSUES_NEW_KEY, 50)
  for (let k = 1; k <= fresh; k++) {
    issues.push(mockNewIssue({ title: `new for me ${k}`, assignee: me, status: 'todo', discussions: [{ task_id: MOCK_DEFAULT_TOPIC }] }, issues.length + 1, MOCK_TEAMMATE, now()))
  }
  /* SPL-2120: `spool.mock.issues-agent` = N issues an agent filed */
  const byAgent = mockStoredCount(MOCK_ISSUES_AGENT_KEY, 50)
  for (let k = 1; k <= byAgent; k++) {
    issues.push(mockNewIssue({ title: `filed by an agent ${k}`, discussions: [{ task_id: MOCK_DEFAULT_TOPIC }] }, issues.length + 1, MOCK_AGENT, now()))
  }
  return issues
}

/* SPL-1027 / SPL-1226: the hub's soft delete (remove) and archive - for the
   mock (no archived store) both hide the row. Without cascade a parent with
   a live child is refused; with it the whole epic / feature and its
   descendants go, and the answer names them. */
function mockDrop(issues, i, cascade, view) {
  if (!i) throw mockErr(404, 'not_found')
  const kids = mockSubtree(issues, i.key)
  if (!cascade && kids.length) throw mockErr(409, 'issue_has_children')
  const gone = cascade ? new Set([i.key, ...kids]) : new Set([i.key])
  return { issues: issues.filter((x) => !gone.has(x.key)), answer: { issue: view(i), descendants: cascade ? kids : [] } }
}

/** a new label from the mock's label call, or the hub's refusal */
function mockNewLabel(labels, { name = '', color = '' } = {}) {
  const id = String(name).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40)
  if (!id) throw mockErr(400, 'bad_issue')
  if (labels.some((l) => l.id === id)) throw mockErr(409, 'label_exists')
  return normalizeLabel({ id, name: String(name).trim(), color: color || '#6b7280' })
}

/* SPL-1643, the hub's epic close: null when the update closes no epic; a
   close of an epic with open issues is refused without the confirmation. */
function mockEpicClose(issues, was, next, confirmed) {
  const closed = (s) => s === 'done' || s === 'diss'
  if (!isTopKind(next.kind) || next.status === was.status || !closed(next.status)) return null
  const kids = mockSubtree(issues, was.key)
  const open = issues.filter((x) => kids.includes(x.key) && !closed(x.status)).map((x) => x.key)
  if (open.length && !confirmed) {
    throw Object.assign(mockErr(409, 'epic_close_confirm'), {
      detail: `${was.key} has ${open.length} open issues: closing it closes and archives them; send cascade: true to confirm`,
    })
  }
  return { kids, open }
}

/* The mock hub's PATCH: the tab's next `issues` and the answer. */
function mockUpdate({ issues, labels, log, me, now }, ref, body) {
  const { cascade, ...patch } = body
  mockEpicField(issues, patch)
  const i = mockFind(issues, ref)
  if (!i) throw mockErr(404, 'not_found')
  const next = normalizeIssue(mockApplyPatch(i, patch, me, now))
  mockCheck(issues, labels, next)
  mockLevelField(issues, patch, next, false)
  const closing = mockEpicClose(issues, i, next, cascade === true)
  let rows = issues.map((x) => (x.key === i.key ? next : x))
  log.changed(i, next)
  const issue = mockView(rows, next)
  if (!closing) return { issues: rows, answer: { issue } }
  /* SPL-1643: its open issues take its status; all of them are archived */
  const gone = new Set([i.key, ...closing.kids])
  rows = rows.filter((x) => !gone.has(x.key))
  return { issues: rows, answer: { issue, archived: true, closed: closing.open, descendants: closing.kids } }
}

/**
 * The mock hub's issues (mock mode, no hub): the same answers as issues-v1,
 * held in memory for the tab. `now` is injectable for tests.
 */
export function createMockIssues({ me = 'HUM-1', now = () => new Date().toISOString() } = {}) {
  /* the tab starts with the "random" epic rdb 0049 gave every tenant, SPL-1;
     since W16 (spec 047) an issue may also stand alone at level 2 */
  let issues = mockSeedIssues(me, now)
  let last = issues.length
  let labels = [normalizeLabel({ id: 'bug', name: 'Bug', color: '#ef4444' }), normalizeLabel({ id: 'epic', name: 'epic', color: '#8b5cf6' })]
  const opened = new Set() /* SPL-1559 (rdb 0184): the keys this viewer opened */
  const mine = (i) => ({ ...i, unopened: unopenedCandidate(i, me) && !opened.has(i.key) })
  const find = (ref) => mockFind(issues, ref)
  const view = (i) => mockView(issues, i)
  const log = mockHistoryLog(issues) /* rdb 0181; a gone issue's history reads 404 */
  const full = (i) => ({ ...i, discussions: mockFullDiscussions(i.discussions) }) /* SPL-1593: a single read's links */
  const relink = (ref, change) => {
    const i = find(ref)
    if (!i) throw mockErr(404, 'not_found')
    const next = change(i)
    issues = issues.map((x) => (x.key === i.key ? next : x))
    return { issue: full(view(next)) }
  }
  const drop = (ref, cascade) => { const r = mockDrop(issues, find(ref), cascade, view); issues = r.issues; return r.answer }
  return {
    list(query = '') {
      const q = new URLSearchParams(query)
      const f = mockFilterOf(q)
      const matched = issues.map(view).map(mine).filter((i) => matchIssue(i, f, me))
      const counts = Object.fromEntries(ISSUE_STATUSES.map((s) => [s, matched.filter((i) => i.status === s).length]))
      const { rows, next } = mockPage(matched, q)
      /* P5-06: like the hub's sheet read, a listed row carries no description;
         the open issue is get(ref) */
      return { prefix: 'SPL', statuses: ISSUE_STATUSES.slice(), counts, issues: rows.map((i) => ({ ...i, description: '' })), labels: labels.slice(), channel: ISSUE_CHANNEL, epics: mockSummaries(issues),
        total: matched.length, next_cursor: next, default_discussion: MOCK_DEFAULT_TOPIC }
    },
    get(ref) {
      const i = find(ref)
      if (!i) throw mockErr(404, 'not_found')
      return { issue: full(mine(view(i))) }
    },
    /* SPL-1593: POST /v1/issues/{ref}/discussions, DELETE .../discussions/{task} */
    link(ref, discussion) { return relink(ref, (i) => mockLinkDiscussion(i, discussion, me, now())) },
    unlink(ref, task) { return relink(ref, (i) => mockUnlinkDiscussion(i, task)) },
    /* SPL-1559: POST /v1/issues/{ref}/opened */
    opened(ref) {
      const i = find(ref)
      if (!i) throw mockErr(404, 'not_found')
      opened.add(i.key)
      return { key: i.key, unopened: false }
    },
    create(body = {}) {
      mockEpicField(issues, body)
      const discussions = mockCreateDiscussions(body, me, now())
      const i = mockNewIssue({ ...body, discussions }, last + 1, me, now())
      mockCheck(issues, labels, i)
      mockLevelField(issues, body, i, true)
      last++
      issues = [...issues, i]
      log.created(i)
      return { issue: full(view(i)) }
    },
    update(ref, body = {}) {
      const out = mockUpdate({ issues, labels, log, me, now }, ref, body)
      issues = out.issues
      return out.answer
    },
    history(ref) { return mockHistoryOf(find(ref), log) },
    remove(ref, cascade = false) { return drop(ref, cascade) },
    archive(ref, cascade = false) { return drop(ref, cascade) },
    label(body = {}) {
      const l = mockNewLabel(labels, body)
      labels = [...labels, l]
      return { label: { ...l } }
    },
  }
}
