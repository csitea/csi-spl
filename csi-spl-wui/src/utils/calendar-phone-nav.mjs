// spec 106 T002: the phone calendar's date arithmetic, pure. CalendarPhone*.vue
// (T004..T010) hold the screens; this answers what they show: the period a
// swipe or `<` / `>` turns to, Month's 6x7 Monday-first grid, the Week strip's
// seven days and its folded empty days ("Thu-Sat"), the header title per
// view (spec 4.1), the next-full-hour preset of the add sheet (4.4), the
// days an event covers (all-day by its UTC date, S4-3) and the local hour
// rows of a Day (23 / 24 / 25 on DST days, S4-6).
//
// Days are 'YYYY-MM-DD' (calendar-year.mjs). Wall clocks are read through
// date-iso-zone.mjs, the one calendar helper allowed to use Intl, so this
// file stays in the calendar's lazy chunk. Names carry "calPhone" because
// Nuxt auto-imports every utils export.

import { calAddDays, calDayMs, calIsoDay, calWeekDays, calWeekday, calWeekStart } from './calendar-year.mjs'
import { isoDateTimeIn } from './date-iso-zone.mjs'

export const CAL_PHONE_VIEWS = ['month', 'week', 'day']
/** English fallbacks; the screens pass `calendar.months` / `calendar.weekdays`. */
export const CAL_PHONE_MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
export const CAL_PHONE_WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']

const HOUR_MS = 3600000
const QUARTER_MS = 900000
const pad = (n) => String(n).padStart(2, '0')

/**
 * The day one period after (`dir` 1) or before (-1) `iso` in `view`. A month
 * step keeps the day of the month, clamped to the target month's last day
 * (2026-01-31 -> 2026-02-28). '' when `iso` is not a day or `view` unknown.
 * @param {string} view 'month' | 'week' | 'day'
 * @param {string} iso
 * @param {number} dir
 * @returns {string}
 */
export function calPhoneStep(view, iso, dir) {
  const ms = calDayMs(iso)
  const n = Math.sign(Number(dir) || 0)
  if (Number.isNaN(ms)) return ''
  if (view === 'day') return calAddDays(iso, n)
  if (view === 'week') return calAddDays(iso, 7 * n)
  if (view !== 'month') return ''
  const d = new Date(ms)
  const y = d.getUTCFullYear()
  const m = d.getUTCMonth() + n
  const last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate()
  return calIsoDay(Date.UTC(y, m, Math.min(d.getUTCDate(), last)))
}

/**
 * Month's grid: 42 cells, Monday first, the month of `iso` in its rows and
 * the neighbour months' days around it (`inMonth` false). Always six rows,
 * so the page never changes height when it turns. [] when not a day.
 * @param {string} iso
 * @returns {{ iso: string, d: number, inMonth: boolean }[]}
 */
export function calPhoneMonthGrid(iso) {
  if (Number.isNaN(calDayMs(iso))) return []
  const start = calWeekStart(`${iso.slice(0, 7)}-01`)
  return Array.from({ length: 42 }, (_, i) => {
    const day = calAddDays(start, i)
    return { iso: day, d: Number(day.slice(8)), inMonth: day.slice(0, 7) === iso.slice(0, 7) }
  })
}

/**
 * The days a view shows around `iso`, as [from, to) - what T004 fetches and
 * prefetches. Month is its 6x7 grid, so the leading and trailing days of the
 * neighbour months get their dots too. null when not a day or view unknown.
 * @param {string} view
 * @param {string} iso
 * @returns {{ from: string, to: string } | null}
 */
export function calPhoneRange(view, iso) {
  if (Number.isNaN(calDayMs(iso))) return null
  if (view === 'day') return { from: iso, to: calAddDays(iso, 1) }
  if (view === 'week') {
    const from = calWeekStart(iso)
    return { from, to: calAddDays(from, 7) }
  }
  if (view !== 'month') return null
  const grid = calPhoneMonthGrid(iso)
  return { from: grid[0].iso, to: calAddDays(grid[41].iso, 1) }
}

/**
 * The Week strip: the seven days, Monday first, of the week holding `iso`.
 * `wd` is 1 = Monday .. 7 = Sunday.
 * @param {string} iso
 * @returns {{ iso: string, d: number, wd: number }[]}
 */
export function calPhoneWeekStrip(iso) {
  return calWeekDays(iso).map((day) => ({ iso: day, d: Number(day.slice(8)), wd: calWeekday(day) }))
}

/**
 * Week's agenda rows: a day with events is a `day` row; each run of empty
 * days folds into one `fold` row (`from`..`to`, "Thu-Sat: nothing planned",
 * spec 4.2). A day in `open` (unfolded by a tap, S2-7) is an `empty` row of
 * its own and splits the run around it, and so is a day `keep` holds: a
 * working day never folds (owner HUM-10, t1 a28dc5c9), so its Working hours
 * line shows; the caller passes the one working-day rule, hoursShowsLine.
 * @param {string[]} days
 * @param {(day: string) => number} countOf events on that day
 * @param {Set<string>} [open]
 * @param {(day: string) => boolean} [keep] a day that never folds
 * @returns {({ kind: 'day' | 'empty', iso: string } | { kind: 'fold', from: string, to: string, days: string[] })[]}
 */
export function calPhoneFoldDays(days, countOf, open = new Set(), keep = () => false) {
  /** @type {({ kind: 'day' | 'empty', iso: string } | { kind: 'fold', from: string, to: string, days: string[] })[]} */
  const out = []
  /** @type {string[]} */
  let run = []
  const flush = () => {
    if (run.length) out.push({ kind: 'fold', from: run[0], to: run[run.length - 1], days: run })
    run = []
  }
  for (const day of days) {
    if ((Number(countOf(day)) || 0) > 0) {
      flush()
      out.push({ kind: 'day', iso: day })
    } else if (open.has(day) || keep(day)) {
      flush()
      out.push({ kind: 'empty', iso: day })
    } else {
      run.push(day)
    }
  }
  flush()
  return out
}

/**
 * A fold row's day names: 'Thu-Sat', or 'Thu' for one day.
 * @param {{ from: string, to: string }} fold
 * @param {string[]} [weekdays] Monday first
 * @returns {string}
 */
export function calPhoneFoldLabel(fold, weekdays = CAL_PHONE_WEEKDAYS) {
  const a = weekdays[calWeekday(fold.from) - 1] || ''
  const b = weekdays[calWeekday(fold.to) - 1] || ''
  return fold.from === fold.to ? a : `${a}-${b}`
}

/**
 * The header title (spec 4.1): `October 2026` in Month, `5-11 Oct 2026` in
 * Week (`28 Sep - 4 Oct 2026`, `28 Dec 2026 - 3 Jan 2027` across a month or a
 * year), `Wed 2026-10-07` in Day. Dates keep the app's ISO style. The short
 * month is the first three letters of `months` unless `monthsShort` is given.
 * @param {string} view
 * @param {string} iso
 * @param {{ months?: string[], monthsShort?: string[], weekdays?: string[] }} [names]
 * @returns {string}
 */
export function calPhoneTitle(view, iso, names = {}) {
  if (Number.isNaN(calDayMs(iso))) return ''
  const months = names.months || CAL_PHONE_MONTHS
  const short = names.monthsShort || months.map((m) => String(m).slice(0, 3))
  const weekdays = names.weekdays || CAL_PHONE_WEEKDAYS
  if (view === 'month') return `${months[Number(iso.slice(5, 7)) - 1]} ${iso.slice(0, 4)}`
  if (view === 'day') return `${weekdays[calWeekday(iso) - 1]} ${iso}`
  if (view !== 'week') return ''
  const part = (/** @type {string} */ day) => ({ d: Number(day.slice(8)), m: short[Number(day.slice(5, 7)) - 1], y: day.slice(0, 4) })
  const from = calWeekStart(iso)
  const a = part(from)
  const b = part(calAddDays(from, 6))
  if (a.y !== b.y) return `${a.d} ${a.m} ${a.y} - ${b.d} ${b.m} ${b.y}`
  if (a.m !== b.m) return `${a.d} ${a.m} - ${b.d} ${b.m} ${b.y}`
  return `${a.d}-${b.d} ${b.m} ${b.y}`
}

/**
 * The add sheet's preset at a tapped hour (4.4): that hour to the next, the
 * end on the next day when the start is 23:00.
 * @param {string} day
 * @param {number} hour 0..23
 * @returns {{ date: string, start: string, endDate: string, end: string } | null}
 */
export function calPhoneHourPreset(day, hour) {
  const h = Math.trunc(Number(hour))
  if (Number.isNaN(calDayMs(day)) || !(h >= 0 && h <= 23)) return null
  const endDate = h === 23 ? calAddDays(day, 1) : day
  return { date: day, start: `${pad(h)}:00`, endDate, end: `${pad((h + 1) % 24)}:00` }
}

/**
 * The add sheet's preset from `+` (4.4): the next full hour of `now` in
 * `zone` (the viewer's when ''), one hour long. 14:00 stays 14:00; 14:01 is
 * 15:00; 23:30 is tomorrow 00:00.
 * @param {Date | number | string} now
 * @param {string} [zone]
 * @returns {{ date: string, start: string, endDate: string, end: string } | null}
 */
export function calPhoneNextFullHour(now, zone = '') {
  const wall = isoDateTimeIn(now, zone)
  if (!wall) return null
  const day = wall.slice(0, 10)
  const h = Number(wall.slice(11, 13)) + (wall.slice(14, 16) === '00' ? 0 : 1)
  return h > 23 ? calPhoneHourPreset(calAddDays(day, 1), 0) : calPhoneHourPreset(day, h)
}

/**
 * The days an event covers, oldest first (S4-3): an all-day event by its UTC
 * date [start, end), never the viewer's zone (midnight UTC is the previous
 * evening west of UTC); a timed one by the wall days of `zone` it touches,
 * an end at 00:00 not counting the day it ends on. [] when unreadable.
 * @param {{ starts_at?: string, ends_at?: string, all_day?: boolean }} ev
 * @param {string} [zone]
 * @returns {string[]}
 */
export function calPhoneEventDays(ev, zone = '') {
  const s = Date.parse(String(ev && ev.starts_at))
  if (Number.isNaN(s)) return []
  const e = Date.parse(String(ev.ends_at))
  const dayOf = (/** @type {number} */ t) => (ev.all_day ? calIsoDay(t) : isoDateTimeIn(t, zone).slice(0, 10))
  const first = dayOf(s)
  const last = Number.isNaN(e) || e <= s ? first : dayOf(e - 1)
  const out = [first]
  while (out[out.length - 1] < last && out.length < 366) out.push(calAddDays(out[out.length - 1], 1))
  return out
}

/**
 * "Day X of Y" of a multi-day event on `day` (Week, S4-3); null when the
 * event lasts one day or does not cover `day`.
 * @param {{ starts_at?: string, ends_at?: string, all_day?: boolean }} ev
 * @param {string} day
 * @param {string} [zone]
 * @returns {{ n: number, of: number } | null}
 */
export function calPhoneSpanOf(ev, day, zone = '') {
  const days = calPhoneEventDays(ev, zone)
  const i = days.indexOf(day)
  return days.length > 1 && i >= 0 ? { n: i + 1, of: days.length } : null
}

/**
 * A Day's hour rows (S4-6): every wall hour of `day` in `zone` (the viewer's
 * when ''), each with the instant it starts. 24 rows on most days, 23 on a
 * spring-forward day (the skipped hour is absent), 25 on a fall-back day
 * (the repeated hour appears twice, labelled twice). [] when not a day.
 * @param {string} day
 * @param {string} [zone]
 * @returns {{ label: string, at: number }[]}
 */
export function calPhoneDayHours(day, zone = '') {
  const ms = calDayMs(day)
  if (Number.isNaN(ms)) return []
  /* the day's first instant: local midnight (or the first instant after a
     midnight gap), found in quarter hours so :30 and :45 zones land on it */
  let t = ms - 15 * HOUR_MS
  const stop = ms + 15 * HOUR_MS
  while (t < stop && isoDateTimeIn(t, zone).slice(0, 10) < day) t += QUARTER_MS
  const rows = []
  for (; rows.length < 26; t += HOUR_MS) {
    const wall = isoDateTimeIn(t, zone)
    if (wall.slice(0, 10) !== day) break
    rows.push({ label: wall.slice(11, 16), at: t })
  }
  return rows
}
