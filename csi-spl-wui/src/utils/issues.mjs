/**
 * Issues, the way Linear keeps them (specs/039, contracts/issues-v1.md).
 * Pure helpers the issues store and the Issues pages share: the workflow
 * order, the priority and level scales, grouping, the hub's sort and filters
 * mirrored client side (so a live frame lands in the right place without a
 * refetch), frame application and the deadline <-> datetime-local bridge.
 */

import { ISSUE_CHANNEL } from './parent-section.mjs'
/** issues-v1 §8: the tree's kinds. Level 1 = epic | feature. */
export const ISSUE_KINDS = ['epic', 'feature', 'issue', 'subtask']
export const isTopKind = (k) => k === 'epic' || k === 'feature'

/** The owner's statuses in list order (rdb 0054, topic f2c32da2): shown as
 *  01-eval, 02-todo, 03-wip, 03-diss, 07-qas, 09-done (issues-v1 §2). */
export const ISSUE_STATUSES = ['eval', 'todo', 'wip', 'diss', 'qas', 'done']
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
  }
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

/** The URL query the hub reads (issues-v1 §4) for a filter + sort. */
export function issueQuery(filter = {}, sort = '') {
  const q = new URLSearchParams()
  if (filter.kind) q.set('kind', filter.kind)
  for (const k of ['epic', 'parent', 'status', 'priority', 'level', 'assignee', 'label']) {
    const v = filter[k]
    if (Array.isArray(v) && v.length) q.set(k, v.join(','))
  }
  if (filter.deadlineBefore) q.set('deadline_before', filter.deadlineBefore)
  if (filter.deadlineAfter) q.set('deadline_after', filter.deadlineAfter)
  if (sort && sort !== 'priority') q.set('sort', sort)
  return q.toString()
}

function mockErr(status, token) {
  return Object.assign(new Error(`spool ${status} ${token}`), { status, token })
}

/**
 * The mock hub's issues (mock mode, no hub): the same answers as issues-v1,
 * held in memory for the tab. `now` is injectable for tests.
 */
export function createMockIssues({ me = 'HUM-1', now = () => new Date().toISOString() } = {}) {
  /* SPL-18: every issue has a parent epic; the tab starts with the "random"
     epic rdb 0049 gives every tenant, SPL-1 */
  let last = 1
  let issues = [normalizeIssue({ key: 'SPL-1', number: 1, title: 'random', kind: 'epic', labels: ['epic'], status: 'in_progress',
    task_id: '00000000-0000-4000-8000-000000000001', created_by: me, updated_by: me, created_at: now(), updated_at: now() })]
  let labels = [normalizeLabel({ id: 'bug', name: 'Bug', color: '#ef4444' }), normalizeLabel({ id: 'epic', name: 'epic', color: '#8b5cf6' })]
  const find = (ref) => {
    const n = Number(String(ref || '').replace(/^[A-Za-z][A-Za-z0-9]*-/, ''))
    return issues.find((i) => i.number === n)
  }
  const apply = (i, b, by) => {
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
  const check = (i) => {
    if (!String(i.title || '').trim()) throw mockErr(400, 'bad_issue')
    if (!ISSUE_STATUSES.includes(i.status)) throw mockErr(400, 'bad_issue')
    if (!(i.priority >= 1 && i.priority <= 5)) throw mockErr(400, 'bad_issue')
    if (i.labels.some((l) => !labels.some((x) => x.id === l))) throw mockErr(400, 'unknown_label')
    const kids = issues.some((x) => x.parent && x.parent === i.key)
    if (isTopKind(i.kind)) {
      if (i.parent) throw mockErr(400, 'bad_epic')
      return
    }
    const was = find(i.key)
    if (was && isTopKind(was.kind) && kids) throw mockErr(409, 'epic_has_issues')
    if (!i.parent) throw mockErr(400, 'epic_required')
    const parent = find(i.parent)
    if (!parent) throw mockErr(400, 'unknown_parent')
    if (isTopKind(parent.kind)) return
    const grand = find(parent.parent)
    if (!grand || !isTopKind(grand.kind) || kids) throw mockErr(400, 'bad_epic')
  }
  /* hub checkEpicField: `epic` names a level-1 row; `parent` also takes a level-2 issue */
  const epicField = (b) => {
    if (!b || !b.epic) return
    const e = find(b.epic)
    if (e && !isTopKind(e.kind)) throw mockErr(400, 'bad_epic')
  }
  /* the stored row -> what the hub answers: kind subtask, the level-1 key and
     the tree's level (rdb 0056: 1 epic / feature, 2 issue, 3 subtask) */
  const view = (i) => {
    if (isTopKind(i.kind)) return { ...i, epic: '', level: 1 }
    const p = find(i.parent)
    if (p && !isTopKind(p.kind)) return { ...i, kind: 'subtask', epic: p.parent, level: 3 }
    return { ...i, kind: 'issue', epic: i.parent, level: 2 }
  }
  /* hub setLevel: a level in the body is only checked against the tree's */
  const levelField = (b, i, create) => {
    const lv = b ? b.level : undefined
    if (lv === undefined || lv === null || (create && lv === 0)) return
    if (!(lv >= 1 && lv <= 3) || lv !== view(i).level) throw mockErr(400, 'bad_issue')
  }
  const summaries = () => issues.filter((e) => isTopKind(e.kind)).map((e) => {
    const mine = issues.filter((i) => !isTopKind(i.kind) && i.parent === e.key)
    const counts = Object.fromEntries(ISSUE_STATUSES.map((st) => [st, mine.filter((i) => i.status === st).length]))
    return { key: e.key, kind: e.kind, number: e.number, title: e.title, status: e.status, total: mine.length, done: counts.done, canceled: counts.diss, counts }
  })
  return {
    list(query = '') {
      const q = new URLSearchParams(query)
      const csv = (k) => (q.get(k) ? q.get(k).split(',') : [])
      const f = { kind: q.get('kind') || '', epic: csv('epic'), parent: csv('parent'), status: csv('status'), priority: csv('priority').map(Number), level: csv('level').map(Number),
        assignee: csv('assignee'), label: csv('label'), deadlineBefore: q.get('deadline_before') || '', deadlineAfter: q.get('deadline_after') || '' }
      const kept = sortIssues(issues.map(view).filter((i) => matchIssue(i, f, me)), q.get('sort') || 'priority')
      const counts = Object.fromEntries(ISSUE_STATUSES.map((s) => [s, kept.filter((i) => i.status === s).length]))
      return { prefix: 'SPL', statuses: ISSUE_STATUSES.slice(), counts, issues: kept, labels: labels.slice(), channel: ISSUE_CHANNEL, epics: summaries() }
    },
    get(ref) {
      const i = find(ref)
      if (!i) throw mockErr(404, 'not_found')
      return { issue: view(i) }
    },
    create(body = {}) {
      epicField(body)
      const at = now()
      const lbl = Array.isArray(body.labels) ? body.labels : []
      const kind = isTopKind(body.kind) ? body.kind : lbl.includes('epic') ? 'epic' : 'issue'
      const i = normalizeIssue({ status: 'eval', ...body, kind, labels: lbl, parent: isTopKind(kind) ? '' : (body.epic || body.parent || ''), key: `SPL-${last + 1}`, number: last + 1,
        task_id: `00000000-0000-4000-8000-${String(last + 1).padStart(12, '0')}`, channel: ISSUE_CHANNEL,
        created_by: me, created_at: at, updated_by: me, updated_at: at })
      check(i)
      levelField(body, i, true)
      last++
      issues = [...issues, i]
      return { issue: view(i) }
    },
    update(ref, patch = {}) {
      epicField(patch)
      const i = find(ref)
      if (!i) throw mockErr(404, 'not_found')
      const next = normalizeIssue(apply(i, patch, me))
      check(next)
      levelField(patch, next, false)
      issues = issues.map((x) => (x.key === i.key ? next : x))
      return { issue: view(next) }
    },
    label({ name = '', color = '' } = {}) {
      const id = String(name).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40)
      if (!id) throw mockErr(400, 'bad_issue')
      if (labels.some((l) => l.id === id)) throw mockErr(409, 'label_exists')
      const l = normalizeLabel({ id, name: String(name).trim(), color: color || '#6b7280' })
      labels = [...labels, l]
      return { label: { ...l } }
    },
  }
}
