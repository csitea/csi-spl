/**
 * Issues list behaviour the page uses. Kept out of the hub client module so
 * the initial script does not carry it (the client only needs the mock and
 * the query string).
 */
import { ISSUE_STATUSES, matchIssue, normalizeIssue, normalizeLabel, sortIssues } from './issues.mjs'
import { storageGetJson, storageSetJson } from './prefs.mjs'
import { PANE_WIDTHS_KEY } from './pane-widths.mjs'

/** Prio is the number 1..5 (rdb 0055 moved the old 0 "none" to 5). */
export const ISSUE_PRIORITIES = [1, 2, 3, 4, 5]
/** The owner's numbered status labels (not translated: they are the owner's
 *  codes); the hover text is issues.status_hint.<id>. */
export const STATUS_LABEL = { eval: '01-eval', todo: '02-todo', wip: '03-wip', diss: '03-diss', qas: '07-qas', done: '09-done' }
export const statusLabel = (s) => STATUS_LABEL[s] || String(s || '')

/** Closed control text is always "Name: value", so two controls cannot read the same. */
export function controlLabel(name, value) {
  const n = String(name ?? '').trim()
  const v = String(value ?? '').trim()
  if (!n) return v
  if (!v) return n
  return n + ': ' + v
}
export const statusHintKey = (s) => `issues.status_hint.${s}`

/** Level is the row's place in the tree (rdb 0056, owner 2026-09-26, SPL-949):
 *  1 epic / feature, 2 issue, 3 subtask. The hub derives it; nobody picks it. */
export const ISSUE_LEVELS = [1, 2, 3]
export const LEVEL_SHORT = ['', '1', '2', '3']

/** Sort keys the hub answers (issues-v1 §4). priority is the default. */
export const ISSUE_SORTS = ['priority', 'level', 'deadline', 'updated', 'created']

/** i18n keys: issues.status.<id>, issues.priority.<n>, issues.level.<n>. */
export const statusKey = (s) => `issues.status.${s}`
export const priorityKey = (p) => `issues.priority.${Number(p) || 0}`
export const levelKey = (l) => `issues.level.${[1, 2, 3].includes(Number(l)) ? Number(l) : 2}`

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

/** Issue detail width, stored beside the other pane widths. */
export const ISSUE_PANE_DEFAULT = 380
export const ISSUE_PANE_MIN = 280
export const ISSUE_PANE_MAX = 720

export function clampIssuePane(width, ceiling = ISSUE_PANE_MAX) {
  const cap = Number(ceiling)
  const hi = Math.max(ISSUE_PANE_MIN, Math.min(ISSUE_PANE_MAX, Number.isFinite(cap) ? cap : ISSUE_PANE_MAX))
  const n = Number(width)
  const v = Number.isFinite(n) ? Math.round(n) : ISSUE_PANE_DEFAULT
  return Math.min(hi, Math.max(ISSUE_PANE_MIN, v))
}

export function loadIssuePane(store) {
  const raw = storageGetJson(PANE_WIDTHS_KEY, null, store)
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return ISSUE_PANE_DEFAULT
  return clampIssuePane(raw.issues)
}

export function saveIssuePane(width, store) {
  const raw = storageGetJson(PANE_WIDTHS_KEY, null, store)
  const prev = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}
  const issues = clampIssuePane(width)
  return storageSetJson(PANE_WIDTHS_KEY, { ...prev, issues }, store)
}

/** Overdue: a deadline in the past on an issue that is not done / canceled. */
export function isOverdue(issue, now = Date.now()) {
  const d = ms(issue && issue.deadline)
  return !Number.isNaN(d) && d < now && issue.status !== 'done' && issue.status !== 'canceled'
}


/**
 * SPL-18: an epic's progress the way Linear shows a project's - done out of
 * the issues that were not canceled, 0..100 (0 when it has none).
 * @param {{ total?: number, done?: number, canceled?: number }} e
 */
export function epicProgress(e) {
  const open = (Number(e && e.total) || 0) - (Number(e && e.canceled) || 0)
  return open > 0 ? Math.round(((Number(e && e.done) || 0) * 100) / open) : 0
}

/* Owner, 2026-09-26 (topic 32a56460): "there should not be am and pm, the
   clock should be 24 hours based, but start from 7 and end till 22". The
   deadline is a date field plus a 24-hour time picker. */
export const DEADLINE_FIRST_HOUR = 7
export const DEADLINE_LAST_HOUR = 22
export const DEADLINE_STEP_MIN = 15
/** The time a deadline gets when only its date is picked. */
export const DEADLINE_DEFAULT_TIME = '09:00'

/**
 * The picker's times, 'HH:MM' 24-hour, 07:00 .. 22:00 every 15 minutes.
 * `keep` (the stored time, e.g. an agent's 23:30) is added in order when it
 * is outside that set, so opening an issue never drops its time.
 */
export function deadlineTimes(keep = '') {
  const out = []
  for (let m = DEADLINE_FIRST_HOUR * 60; m <= DEADLINE_LAST_HOUR * 60; m += DEADLINE_STEP_MIN) {
    out.push(`${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`)
  }
  if (/^\d{2}:\d{2}$/.test(keep) && !out.includes(keep)) {
    out.push(keep)
    out.sort()
  }
  return out
}

/** 'YYYY-MM-DDTHH:MM' (local) -> { date, time }; '' -> both ''. */
export function splitLocal(local) {
  const m = String(local || '').match(/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/)
  return m ? { date: m[1], time: m[2] } : { date: '', time: '' }
}

/** date + time -> 'YYYY-MM-DDTHH:MM' (local); no date -> '' (clears). */
export function joinLocal(date, time) {
  const d = String(date || '').trim()
  if (!/^\d{4}-\d{2}-\d{2}$/.test(d)) return ''
  const t = /^\d{2}:\d{2}$/.test(String(time || '')) ? time : DEADLINE_DEFAULT_TIME
  return `${d}T${t}`
}
