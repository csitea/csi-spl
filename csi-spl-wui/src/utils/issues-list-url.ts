// SPL-4648 (owner, t1 e04820a5: "the full state of the issues listing should be
// setable from the URL of it"): what the Issues list's address says, and back.
// A value it cannot use reads as not named, so a bad link never blanks the page.
// `epic` and `issue` keep their own writers; every other parameter passes through.
import { ISSUE_STATUSES } from '~/utils/issues.mjs'
import { ISSUE_LEVELS, ISSUE_PRIORITIES, sortFromQuery } from '~/utils/issues-view.mjs'
import { ISSUES_VIEWS, type IssuesView } from '~/utils/view-prefs.mjs'

export type IssueListQueryState = {
  view: IssuesView | ''
  sort: { col: string, dir: string }
  unread: boolean
  status: string
  priority: string
  level: string
  assignee: string
  label: string
  deadline: string
  fold: string[] | null
}

/** The parameters listStateQuery owns, as spec 039 names them. */
export const LIST_PARAMS = ['view', 'sort', 'dir', 'unread', 'status', 'priority', 'level', 'assignee', 'label', 'deadline', 'fold']

const one = (v: unknown): string => {
  const raw = Array.isArray(v) ? v[0] : v
  return typeof raw === 'string' ? raw.trim() : ''
}
const inList = (list: readonly (string | number)[], v: string): string => (list.map(String).includes(v) ? v : '')

/** The deadline filter is a local day and minute; a date that does not exist is not named. */
function validDeadline(v: string): string {
  const m = v.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/)
  if (!m) return ''
  const [y, mo, d, h, mi] = m.slice(1).map(Number) as [number, number, number, number, number]
  const at = new Date(Date.UTC(y, mo - 1, d, h, mi))
  return at.getUTCMonth() === mo - 1 && at.getUTCDate() === d && at.getUTCHours() === h && at.getUTCMinutes() === mi ? v : ''
}

/**
 * A route query as the list's state. `fold` is null when the URL does not name
 * it. The viewer's own id reads as the "me" filter, so their picker stays on it.
 */
export function listStateFromQuery(q: Record<string, unknown> = {}, me = ''): IssueListQueryState {
  const assignee = one(q.assignee)
  return {
    view: inList(ISSUES_VIEWS, one(q.view)) as IssuesView | '',
    sort: sortFromQuery(q),
    unread: one(q.unread) === '1',
    status: inList(ISSUE_STATUSES, one(q.status)),
    priority: inList(ISSUE_PRIORITIES, one(q.priority)),
    level: inList(ISSUE_LEVELS, one(q.level)),
    assignee: me && assignee === me ? 'me' : assignee,
    label: one(q.label),
    deadline: validDeadline(one(q.deadline)),
    fold: q.fold === undefined ? null : one(q.fold).split(',').filter((s) => (ISSUE_STATUSES as readonly string[]).includes(s)),
  }
}

/**
 * The query for that state over `base`. "me" is written as the viewer's id: the
 * link is pasted to someone else, and it means the same person there.
 */
export function listStateQuery(s: Partial<IssueListQueryState>, base: Record<string, string> = {}, me = ''): Record<string, string> {
  const q: Record<string, string> = { ...base }
  for (const k of LIST_PARAMS) delete q[k]
  if (s.view) q.view = s.view
  if (s.sort && s.sort.col) { q.sort = s.sort.col; q.dir = s.sort.dir }
  if (s.unread) q.unread = '1'
  for (const k of ['status', 'priority', 'level', 'label', 'deadline'] as const) { const v = s[k]; if (v) q[k] = v }
  if (s.assignee) q.assignee = s.assignee === 'me' && me ? me : s.assignee
  const fold = ISSUE_STATUSES.filter((st) => (s.fold || []).includes(st))
  if (fold.length) q.fold = fold.join(',')
  return q
}

/** Whether two queries name the same parameters and values, in any order. */
export function sameQuery(a: Record<string, string>, b: Record<string, string>): boolean {
  const flat = (q: Record<string, string>) => JSON.stringify(Object.entries(q).map(([k, v]) => [k, String(v)]).sort(([x], [y]) => (x < y ? -1 : x > y ? 1 : 0)))
  return flat(a) === flat(b)
}
