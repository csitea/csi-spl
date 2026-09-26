/**
 * Issues list behaviour the page uses. Kept out of the hub client module so
 * the initial script does not carry it (the client only needs the mock and
 * the query string).
 */
import { ISSUE_STATUSES, matchIssue, normalizeIssue, normalizeLabel, sortIssues } from './issues.mjs'

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


const ms = (s) => {
  const t = Date.parse(String(s || ''))
  return Number.isFinite(t) ? t : NaN
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

