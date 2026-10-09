/**
 * Spec 107 v1.2 T015 (sections 4.3, 4.4, 5.4, 6.2; owner R11): the Team and
 * Download tabs of the calendar's hours panel, pure. The Team grid is drawn
 * from one GET /v1/hours?period= answer (T008: `period`, `members`,
 * `entries`, approved entries only); the filters (member, target kind, one
 * topic or issue) narrow it here, so a filter change costs no request.
 * Loaded only by the panel's lazy Team / Download chunks.
 */
import { hoursAddDays } from './hours-calendar.mjs'

/** the target kinds of the filter, in the hub's prefixes (`ws` = other) */
export const HOURS_TEAM_KINDS = ['t', 'ch', 'dm', 'cal', 'ws']

/** the most days a grid draws (a month period is 31) */
const MAX_DAYS = 62

/** The kind prefix of a target: `t:<id>` -> `t`, anything unprefixed -> `ws`. */
export function hoursTargetKind(target) {
  const m = String(target || '').match(/^(t|ch|dm|cal):/)
  return m ? m[1] : 'ws'
}

/** Every day of `period` ({ start, end }, YYYY-MM-DD, inclusive). */
export function hoursPeriodDays(period) {
  const start = String(period?.start || '')
  const end = String(period?.end || '')
  const out = []
  if (!/^\d{4}-\d{2}-\d{2}$/.test(start) || !/^\d{4}-\d{2}-\d{2}$/.test(end)) return out
  for (let d = start; d <= end && out.length < MAX_DAYS; d = hoursAddDays(d, 1)) out.push(d)
  return out
}

/**
 * Does an entry pass the filter? `member` = one HUM-*, `kind` = a prefix of
 * HOURS_TEAM_KINDS, `target` = one exact target (a topic, an issue's topic).
 * @param {{ member_id: string, target: string }} e
 * @param {{ member?: string, kind?: string, target?: string }} f
 */
export function hoursTeamKeeps(e, f = {}) {
  if (f.member && e.member_id !== f.member) return false
  if (f.kind && hoursTargetKind(e.target) !== f.kind) return false
  if (f.target && e.target !== f.target) return false
  return true
}

/**
 * The Team grid (spec 5.4): members x days of the period, approved minutes
 * per cell, totals per row and per column, each member's per-target
 * breakdown, and its period state. A member filter keeps one row; a kind or
 * target filter keeps every member (a zero row says "nothing of that kind").
 * @param {any} body a GET /v1/hours answer
 * @param {{ member?: string, kind?: string, target?: string }} [f]
 */
export function hoursTeamGrid(body, f = {}) {
  const days = hoursPeriodDays(body?.period)
  const col = new Map(days.map((d, i) => [d, i]))
  const rows = []
  const byMember = new Map()
  for (const m of Array.isArray(body?.members) ? body.members : []) {
    if (!m || !m.member_id || (f.member && m.member_id !== f.member)) continue
    const row = {
      member: String(m.member_id),
      name: String(m.name || m.member_id),
      state: String(m.state || 'open'),
      note: String(m.note || ''),
      cells: days.map(() => 0),
      total: 0,
      /** @type {{ target: string, minutes: number }[]} */
      targets: [],
    }
    rows.push(row)
    byMember.set(row.member, { row, targets: new Map() })
  }
  const cols = days.map(() => 0)
  let total = 0
  for (const e of Array.isArray(body?.entries) ? body.entries : []) {
    if (!e || !hoursTeamKeeps(e, f)) continue
    const at = byMember.get(e.member_id)
    const i = col.get(e.day)
    const min = Math.max(0, Number(e.minutes) || 0)
    if (!at || i === undefined || !min) continue
    at.row.cells[i] += min
    at.row.total += min
    cols[i] += min
    total += min
    at.targets.set(e.target, (at.targets.get(e.target) || 0) + min)
  }
  for (const { row, targets } of byMember.values()) {
    row.targets = [...targets].map(([target, minutes]) => ({ target, minutes })).sort((a, b) => b.minutes - a.minutes || (a.target < b.target ? -1 : 1))
  }
  return { days, rows, cols, total, frozen: rows.filter((r) => r.state === 'frozen').length }
}

/** The topics (`t:` targets, an issue is its topic) the period's entries hold, for the issue filter. */
export function hoursTeamTopics(body) {
  const seen = new Set()
  for (const e of Array.isArray(body?.entries) ? body.entries : []) {
    if (e && hoursTargetKind(e.target) === 't') seen.add(String(e.target))
  }
  return [...seen].sort()
}

/** The download's path (spec 6.2, T009): the period holding `day`. */
export function hoursExportPath(day, format, final) {
  const f = format === 'xlsx' ? 'xlsx' : 'csv'
  return `/v1/hours/export?period=${encodeURIComponent(String(day || ''))}&format=${f}&final=${final ? 'true' : 'false'}`
}

/** The file name of a Content-Disposition `attachment; filename="..."`, else `fallback`. */
export function hoursDownloadName(disposition, fallback) {
  const m = String(disposition || '').match(/filename="([^"/\\]+)"/)
  return m ? m[1] : fallback
}

/**
 * The PUT /v1/hours/periods body (T008): approve or return the frozen rows
 * of `members` (none = Approve all / Return all); a return carries its note.
 */
export function hoursDecision(period, action, members, note) {
  const body = { period: String(period || ''), action: action === 'return' ? 'return' : 'approve' }
  if (Array.isArray(members) && members.length) body.members = members.map(String)
  if (body.action === 'return') body.note = String(note || '').trim()
  return body
}
