/**
 * Issues, the way Linear keeps them (specs/039, contracts/issues-v1.md).
 * Pure helpers the issues store and the Issues pages share: the workflow
 * order, the priority and level scales, grouping, the hub's sort and filters
 * mirrored client side (so a live frame lands in the right place without a
 * refetch), frame application and the deadline <-> datetime-local bridge.
 */

/** Linear's workflow, in list order (issues-v1 §2). */
export const ISSUE_STATUSES = ['backlog', 'todo', 'in_progress', 'in_review', 'done', 'canceled']

/** 0 no priority, 1 urgent, 2 high, 3 medium, 4 low (Linear's scale). */
export const ISSUE_PRIORITIES = [0, 1, 2, 3, 4]

/** The owner's "level": Linear's t-shirt estimate. 0 none, 1 XS .. 5 XL. */
export const ISSUE_LEVELS = [0, 1, 2, 3, 4, 5]
export const LEVEL_SHORT = ['', 'XS', 'S', 'M', 'L', 'XL']

/** Sort keys the hub answers (issues-v1 §4). priority is the default. */
export const ISSUE_SORTS = ['priority', 'level', 'deadline', 'updated', 'created']

/** i18n keys: issues.status.<id>, issues.priority.<n>, issues.level.<n>. */
export const statusKey = (s) => `issues.status.${s}`
export const priorityKey = (p) => `issues.priority.${Number(p) || 0}`
export const levelKey = (l) => `issues.level.${Number(l) || 0}`

/** One issue as the hub sent it, with every field present and typed. */
export function normalizeIssue(raw) {
  const r = raw || {}
  return {
    key: String(r.key || ''),
    number: Number(r.number) || 0,
    title: String(r.title || ''),
    description: String(r.description || ''),
    status: ISSUE_STATUSES.includes(r.status) ? r.status : 'backlog',
    priority: Number(r.priority) || 0,
    level: Number(r.level) || 0,
    assignee: String(r.assignee || ''),
    labels: Array.isArray(r.labels) ? r.labels.map(String) : [],
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
 * @param {{ status?: string[], priority?: number[], level?: number[], assignee?: string[], label?: string[], deadlineBefore?: string, deadlineAfter?: string }} f
 * @param {string} [me]
 */
export function matchIssue(issue, f = {}, me = '') {
  const has = (a) => Array.isArray(a) && a.length > 0
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
 * The middle pane: one group per status in workflow order, each with its
 * sorted issues and count. Empty groups are kept (Linear shows the header
 * with 0) unless `hideEmpty`.
 */
export function groupIssues(list, { sort = 'priority', filter = {}, me = '', hideEmpty = false } = {}) {
  const kept = (list || []).filter((i) => matchIssue(i, filter, me))
  const groups = ISSUE_STATUSES.map((status) => {
    const issues = sortIssues(kept.filter((i) => i.status === status), sort)
    return { status, count: issues.length, issues }
  })
  return hideEmpty ? groups.filter((g) => g.count > 0) : groups
}

/** The rows in on-screen order (for J / K), collapsed groups skipped. */
export function visibleOrder(groups, collapsed = {}) {
  const out = []
  for (const g of groups || []) if (!collapsed[g.status]) out.push(...g.issues)
  return out
}

/** J / K: the key after (+1) or before (-1) `current`, clamped; the first when none. */
export function stepKey(order, current, delta) {
  const keys = (order || []).map((i) => i.key)
  if (!keys.length) return ''
  const at = keys.indexOf(current)
  if (at < 0) return delta < 0 ? keys[keys.length - 1] : keys[0]
  return keys[Math.min(keys.length - 1, Math.max(0, at + delta))]
}

/** An `issue` frame (create / update) merged into the held list, by key. */
export function applyIssueFrame(list, frame) {
  const f = frame || {}
  if (f.type !== 'issue' || !f.issue) return list
  const next = normalizeIssue(f.issue)
  if (!next.key) return list
  const out = (list || []).slice()
  const at = out.findIndex((i) => i.key === next.key)
  if (at < 0) out.push(next)
  else if (!out[at].updated_at || !next.updated_at || ms(next.updated_at) >= ms(out[at].updated_at)) out[at] = next
  return out
}

/** An `issue_label` frame added to the catalogue (sorted by name). */
export function applyLabelFrame(labels, frame) {
  const f = frame || {}
  if (f.type !== 'issue_label' || !f.label) return labels
  const l = normalizeLabel(f.label)
  if (!l.id || (labels || []).some((x) => x.id === l.id)) return labels
  return [...(labels || []), l].sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()) || a.id.localeCompare(b.id))
}

/** An optimistic patch applied locally (the hub's answer replaces it). */
export function patchIssue(issue, patch) {
  return { ...issue, ...patch }
}

const pad = (n) => String(n).padStart(2, '0')

/**
 * The deadline for `<input type="datetime-local">`: the stored UTC instant in
 * the viewer's local time, 'YYYY-MM-DDTHH:MM'. '' when unset or unreadable.
 * `offsetMin` overrides the zone (tests); default is the browser's.
 */
export function deadlineToLocalInput(iso, offsetMin) {
  const t = ms(iso)
  if (Number.isNaN(t)) return ''
  const off = offsetMin === undefined ? -new Date(t).getTimezoneOffset() : offsetMin
  const d = new Date(t + off * 60000)
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`
}

/**
 * The datetime-local value back to the RFC 3339 UTC string the hub stores.
 * '' clears. null when the value is not a date-time.
 */
export function localInputToDeadline(value, offsetMin) {
  const v = String(value || '').trim()
  if (!v) return ''
  const m = v.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/)
  if (!m) return null
  const [, y, mo, d, h, mi, s] = m.map(Number)
  const asUTC = Date.UTC(y, mo - 1, d, h, mi, s || 0)
  const off = offsetMin === undefined ? -new Date(asUTC).getTimezoneOffset() : offsetMin
  return new Date(asUTC - off * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z')
}

/** Overdue: a deadline in the past on an issue that is not done / canceled. */
export function isOverdue(issue, now = Date.now()) {
  const d = ms(issue && issue.deadline)
  return !Number.isNaN(d) && d < now && issue.status !== 'done' && issue.status !== 'canceled'
}

/** The URL query the hub reads (issues-v1 §4) for a filter + sort. */
export function issueQuery(filter = {}, sort = '') {
  const q = new URLSearchParams()
  for (const k of ['status', 'priority', 'level', 'assignee', 'label']) {
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
  let last = 0
  let issues = []
  let labels = [normalizeLabel({ id: 'bug', name: 'Bug', color: '#ef4444' })]
  const find = (ref) => {
    const n = Number(String(ref || '').replace(/^[A-Za-z][A-Za-z0-9]*-/, ''))
    return issues.find((i) => i.number === n)
  }
  const apply = (i, b, by) => {
    const out = { ...i }
    for (const k of ['title', 'description', 'status', 'priority', 'level', 'assignee', 'labels', 'deadline', 'parent']) {
      if (b[k] !== undefined && b[k] !== null) out[k] = k === 'labels' ? b[k].slice() : b[k]
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
  }
  return {
    list(query = '') {
      const q = new URLSearchParams(query)
      const csv = (k) => (q.get(k) ? q.get(k).split(',') : [])
      const f = { status: csv('status'), priority: csv('priority').map(Number), level: csv('level').map(Number),
        assignee: csv('assignee'), label: csv('label'), deadlineBefore: q.get('deadline_before') || '', deadlineAfter: q.get('deadline_after') || '' }
      const kept = sortIssues(issues.filter((i) => matchIssue(i, f, me)), q.get('sort') || 'priority')
      const counts = Object.fromEntries(ISSUE_STATUSES.map((s) => [s, kept.filter((i) => i.status === s).length]))
      return { prefix: 'SPL', statuses: ISSUE_STATUSES.slice(), counts, issues: kept, labels: labels.slice(), channel: 'tasks' }
    },
    get(ref) {
      const i = find(ref)
      if (!i) throw mockErr(404, 'not_found')
      return { issue: { ...i } }
    },
    create(body = {}) {
      const at = now()
      const i = normalizeIssue({ status: 'backlog', ...body, key: `SPL-${last + 1}`, number: last + 1,
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
