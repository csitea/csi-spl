/**
 * Issues, the way Linear keeps them (specs/039, contracts/issues-v1.md).
 * Pure helpers the issues store and the Issues pages share: the workflow
 * order, the priority and level scales, grouping, the hub's sort and filters
 * mirrored client side (so a live frame lands in the right place without a
 * refetch), frame application and the deadline <-> datetime-local bridge.
 */

/** Linear's workflow, in list order (issues-v1 §2). */
export const ISSUE_STATUSES = ['backlog', 'todo', 'in_progress', 'in_review', 'done', 'canceled']

/** One issue as the hub sent it, with every field present and typed. */
export function normalizeIssue(raw) {
  const r = raw || {}
  const labels = Array.isArray(r.labels) ? r.labels.map(String) : []
  /* SPL-18: an epic is an issue with the reserved label `epic` */
  const kind = r.kind === 'epic' || (!r.kind && labels.includes('epic')) ? 'epic' : 'issue'
  return {
    kind,
    epic: kind === 'epic' ? '' : String(r.epic || r.parent || ''),
    key: String(r.key || ''),
    number: Number(r.number) || 0,
    title: String(r.title || ''),
    description: String(r.description || ''),
    status: ISSUE_STATUSES.includes(r.status) ? r.status : 'backlog',
    priority: Number(r.priority) || 0,
    level: Number(r.level) || 0,
    assignee: String(r.assignee || ''),
    labels,
    deadline: String(r.deadline || ''),
    parent: String(r.parent || ''),
    task_id: String(r.task_id || ''),
    channel: String(r.channel || 'tasks'),
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

const prioRank = (p) => (Number(p) === 0 ? 5 : Number(p))
const ms = (s) => {
  const t = Date.parse(String(s || ''))
  return Number.isFinite(t) ? t : NaN
}

/**
 * The hub's order (hub.SortIssues): priority urgent first and none last;
 * level largest first; deadline soonest first and none last; updated /
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
        c = (Number(y.level) || 0) - (Number(x.level) || 0)
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
  if (f.kind && issue.kind !== f.kind) return false
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
  for (const k of ['epic', 'status', 'priority', 'level', 'assignee', 'label']) {
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
    for (const k of ['title', 'description', 'status', 'priority', 'level', 'assignee', 'labels', 'deadline']) {
      if (b[k] !== undefined && b[k] !== null) out[k] = k === 'labels' ? b[k].slice() : b[k]
    }
    if (b.epic !== undefined || b.parent !== undefined) out.epic = String(b.epic ?? b.parent ?? '')
    if (b.kind === 'epic' || b.kind === 'issue') {
      out.kind = b.kind
      out.labels = out.labels.filter((l) => l !== 'epic').concat(b.kind === 'epic' ? ['epic'] : [])
      if (b.kind === 'epic') out.epic = ''
    }
    if (out.status !== i.status) {
      out.completed_at = out.status === 'done' ? now() : ''
      out.canceled_at = out.status === 'canceled' ? now() : ''
    }
    out.updated_by = by
    out.updated_at = now()
    return out
  }
  const check = (i) => {
    if (!String(i.title || '').trim()) throw mockErr(400, 'bad_issue')
    if (!ISSUE_STATUSES.includes(i.status)) throw mockErr(400, 'bad_issue')
    if (i.labels.some((l) => !labels.some((x) => x.id === l))) throw mockErr(400, 'unknown_label')
    if (i.kind === 'epic') {
      if (i.epic) throw mockErr(400, 'bad_epic')
      return
    }
    if (issues.some((x) => x.epic && x.epic === i.key)) throw mockErr(409, 'epic_has_issues')
    if (!i.epic) throw mockErr(400, 'epic_required')
    const parent = find(i.epic)
    if (!parent || parent.kind !== 'epic') throw mockErr(400, 'bad_epic')
  }
  const summaries = () => issues.filter((e) => e.kind === 'epic').map((e) => {
    const mine = issues.filter((i) => i.kind !== 'epic' && i.epic === e.key)
    const counts = Object.fromEntries(ISSUE_STATUSES.map((st) => [st, mine.filter((i) => i.status === st).length]))
    return { key: e.key, number: e.number, title: e.title, status: e.status, total: mine.length, done: counts.done, canceled: counts.canceled, counts }
  })
  return {
    list(query = '') {
      const q = new URLSearchParams(query)
      const csv = (k) => (q.get(k) ? q.get(k).split(',') : [])
      const f = { kind: q.get('kind') || '', epic: csv('epic'), status: csv('status'), priority: csv('priority').map(Number), level: csv('level').map(Number),
        assignee: csv('assignee'), label: csv('label'), deadlineBefore: q.get('deadline_before') || '', deadlineAfter: q.get('deadline_after') || '' }
      const kept = sortIssues(issues.filter((i) => matchIssue(i, f, me)), q.get('sort') || 'priority')
      const counts = Object.fromEntries(ISSUE_STATUSES.map((s) => [s, kept.filter((i) => i.status === s).length]))
      return { prefix: 'SPL', statuses: ISSUE_STATUSES.slice(), counts, issues: kept, labels: labels.slice(), channel: 'tasks', epics: summaries() }
    },
    get(ref) {
      const i = find(ref)
      if (!i) throw mockErr(404, 'not_found')
      return { issue: { ...i } }
    },
    create(body = {}) {
      const at = now()
      const kind = body.kind === 'epic' ? 'epic' : 'issue'
      const lbl = (Array.isArray(body.labels) ? body.labels : []).filter((l) => l !== 'epic').concat(kind === 'epic' ? ['epic'] : [])
      const i = normalizeIssue({ status: 'backlog', ...body, kind, labels: lbl, epic: kind === 'epic' ? '' : (body.epic || body.parent || ''), key: `SPL-${last + 1}`, number: last + 1,
        task_id: `00000000-0000-4000-8000-${String(last + 1).padStart(12, '0')}`, channel: 'tasks',
        created_by: me, created_at: at, updated_by: me, updated_at: at })
      check(i)
      last++
      issues = [...issues, i]
      return { issue: { ...i } }
    },
    update(ref, patch = {}) {
      const i = find(ref)
      if (!i) throw mockErr(404, 'not_found')
      const next = normalizeIssue(apply(i, patch, me))
      check(next)
      issues = issues.map((x) => (x.key === i.key ? next : x))
      return { issue: { ...next } }
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
