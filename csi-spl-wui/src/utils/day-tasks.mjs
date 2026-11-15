// Spec 170 row B1 (owner HUM-10, csitea, topic dfe850d9): the task rules of
// the Calendar's To-do view and of the morning card, pure, so the list and the
// number never disagree (spec 170 section 5). Q3 = A (msg 446d58a3): overdue
// tasks show above today's, marked, and count in the signal.
//
// Days are 'YYYY-MM-DD' (calendar-year.mjs). `zone` is an IANA zone; "" or an
// unknown one is the viewer's (the picked zone, else the browser's). Wall
// clocks are read through date-iso-zone.mjs, so this file stays lazy: nothing
// in the first screen may import it. Not the isOverdue of issues-view.mjs:
// that one turns overdue the minute the time passes and reads `diss` as open
// (spec 170 section 2).

import { calAddDays, calDayMs } from './calendar-year.mjs'
import { isoDateTimeIn } from './date-iso-zone.mjs'
import { OPEN_ISSUE_STATUSES, openIssueCount } from './my-issues-count.mjs'

const MINUTE_MS = 60000
/* The first instant of a day is within this of its 00:00 UTC: the offsets run
   from -12 to +14 hours, and a daylight change can skip a local midnight. */
const SEARCH_MS = 15 * 3600000

const dayIn = (value, zone) => isoDateTimeIn(value, zone).slice(0, 10)

/** The day a task's deadline falls on in `zone`. */
const taskDay = (issue, zone) => dayIn(issue.deadline, zone)

/** Oldest deadline first. */
const byDeadline = (a, b) => Date.parse(a.deadline) - Date.parse(b.deadline)

/**
 * A task: an open issue, not an epic or a feature, with a deadline. `diss` is
 * closed, as in the store.
 * @param {unknown} issue
 * @returns {boolean}
 */
export function isTask(issue) {
  if (openIssueCount([issue]) !== 1) return false
  return !Number.isNaN(Date.parse(/** @type {{ deadline?: string }} */ (issue).deadline ?? ''))
}

/**
 * The first instant of `day` in `zone`: not always 00:00, a daylight change
 * can start a day at 01:00, and a day can last 23 or 25 hours.
 * @param {string} day
 * @param {string} zone
 * @returns {number}
 */
function dayStartMs(day, zone) {
  const utcMs = calDayMs(day)
  let before = utcMs - SEARCH_MS
  let from = utcMs + SEARCH_MS
  while (from - before > MINUTE_MS) {
    const mid = before + Math.floor((from - before) / (2 * MINUTE_MS)) * MINUTE_MS
    if (dayIn(mid, zone) < day) before = mid
    else from = mid
  }
  return from
}

/**
 * The instants that bound `day` in `zone`, RFC 3339, as the hub reads them:
 * `deadline_after=start` and `deadline_before=end` are exactly [start, end),
 * so two neighbouring days never count a task twice. null when not a day.
 * @param {string} day
 * @param {string} [zone]
 * @returns {{ start: string, end: string } | null}
 */
export function dayBounds(day, zone = '') {
  if (Number.isNaN(calDayMs(day))) return null
  return {
    start: new Date(dayStartMs(day, zone)).toISOString(),
    end: new Date(dayStartMs(calAddDays(day, 1), zone)).toISOString(),
  }
}

/**
 * Every day of the [from, to) a view reads (calDeskRange), in order, with its
 * tasks, earliest deadline first. An empty day stays in the list: the view
 * decides whether it says so or leaves it out (spec 170 section 4.3). [] when
 * `range` is not two days.
 * @param {unknown} issues
 * @param {{ from: string, to: string } | null | undefined} range
 * @param {string} [zone]
 * @returns {{ day: string, tasks: any[] }[]}
 */
export function groupByDay(issues, range, zone = '') {
  const groups = []
  if (!range || Number.isNaN(calDayMs(range.from)) || Number.isNaN(calDayMs(range.to))) return groups
  const tasks = Array.isArray(issues) ? issues.filter(isTask) : []
  for (let day = range.from; day < range.to; day = calAddDays(day, 1)) {
    groups.push({ day, tasks: tasks.filter((t) => taskDay(t, zone) === day).sort(byDeadline) })
  }
  return groups
}

/**
 * The tasks due before today in `zone`, oldest first. A task due today at
 * 09:00 is not one of them at 10:00: it stays under today (spec 170 section 2).
 * @param {unknown} issues
 * @param {Date | number} now
 * @param {string} [zone]
 * @returns {any[]}
 */
export function overdue(issues, now, zone = '') {
  const today = dayIn(now, zone)
  if (!today || !Array.isArray(issues)) return []
  return issues.filter((i) => isTask(i) && taskDay(i, zone) < today).sort(byDeadline)
}

/**
 * What the morning card counts: the tasks due today and the overdue ones, the
 * same rows the Day range on today lists.
 * @param {unknown} issues
 * @param {Date | number} now
 * @param {string} [zone]
 * @returns {{ today: number, overdue: number }}
 */
export function dueTodayCounts(issues, now, zone = '') {
  const today = dayIn(now, zone)
  if (!today || !Array.isArray(issues)) return { today: 0, overdue: 0 }
  return {
    today: issues.filter((i) => isTask(i) && taskDay(i, zone) === today).length,
    overdue: overdue(issues, now, zone).length,
  }
}

/* Spec 170 row B2: what the desktop To-do view reads and shows. */

/** True when `day` is one of the [from, to) days of `range`. */
const holds = (range, day) => Boolean(range) && range.from <= day && day < range.to

/**
 * The two GET /v1/issues filters of a To-do range (spec 170 section 11.2):
 * `window` = the open tasks due in [first day, day after the last) and, when
 * the range holds `today`, `overdue` = the open tasks due before today (else
 * null). Epics and features are left out by the hub (`kind`) and again by
 * isTask. `mine` adds assignee=me (owner Q2 = A: mine, with a switch). null
 * when `range` is not two days.
 * @param {{ range: { from: string, to: string } | null | undefined, today: string, mine: boolean, zone?: string }} o
 * @returns {{ window: Record<string, unknown>, overdue: Record<string, unknown> | null } | null}
 */
export function taskFilters({ range, today, mine, zone = '' }) {
  const from = range ? dayBounds(range.from, zone) : null
  const to = range ? dayBounds(range.to, zone) : null
  if (!from || !to) return null
  const base = { kind: 'issue,subtask', status: [...OPEN_ISSUE_STATUSES], assignee: mine ? ['me'] : [] }
  const start = holds(range, today) ? dayBounds(today, zone) : null
  return {
    window: { ...base, deadlineAfter: from.start, deadlineBefore: to.start },
    overdue: start ? { ...base, deadlineBefore: start.start } : null,
  }
}

/**
 * The sections of a To-do range, top to bottom (spec 170 sections 4.3, 4.4):
 * when the range holds `today`, the overdue tasks first (`overdue: true`,
 * day ''), then the days from today on, so a task is listed once; else
 * every day. `keepEmpty` keeps a day with no task (the Day range says so in
 * one line); the longer ranges leave it out.
 * @param {{ rows: unknown, late: unknown, range: { from: string, to: string } | null | undefined, now: Date | number, zone?: string, keepEmpty?: boolean }} o
 * @returns {{ day: string, overdue: boolean, tasks: any[] }[]}
 */
export function todoSections({ rows, late, range, now, zone = '', keepEmpty = false }) {
  const today = dayIn(now, zone)
  const holdsToday = holds(range, today)
  const days = groupByDay(rows, range, zone)
    .filter((g) => (!holdsToday || g.day >= today) && (keepEmpty || g.tasks.length > 0))
    .map((g) => ({ ...g, overdue: false }))
  const lateTasks = holdsToday ? overdue(late, now, zone) : []
  return lateTasks.length ? [{ day: '', overdue: true, tasks: lateTasks }, ...days] : days
}
