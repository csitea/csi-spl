// SPL-4060 (owner HUM-10, t1 080e1f77, poll 7c472af4): the desktop
// calendar's views, pure. The vertical tab group at the grid's left edge
// picks one of Day, 3 days, Week and Month; this answers which days each
// shows around the focus day, the [from, to) it reads, where previous /
// next go and how tall an hour row is so 8 hours are on screen at once.
//
// Days are 'YYYY-MM-DD' (calendar-year.mjs). Names carry "calDesk" because
// Nuxt auto-imports every utils export.

import { calAddDays, calDayMs, calWeekDays } from './calendar-year.mjs'
import { calDayCompare, calPhoneEventDays, calPhoneMonthGrid, calPhoneStep } from './calendar-phone-nav.mjs'

/** The views of the tab group, top to bottom; 'week' is the default. */
export const CAL_DESK_VIEWS = ['day', '3day', 'week', 'month']
/** The time grid shows this many hours at once (owner msg f1003a7a) ... */
export const CAL_DESK_WINDOW_H = 8
/** ... from 09:00 (poll 7c472af4 Q2 W9); the rest is a scroll away. */
export const CAL_DESK_OPEN_MIN = 9 * 60
/** An hour row never gets shorter than this, on a short window. */
export const CAL_DESK_MIN_HOUR_PX = 40

/**
 * The view named by a ?v= value, 'week' for anything else.
 * @param {unknown} v
 * @returns {'day' | '3day' | 'week' | 'month'}
 */
export function calDeskView(v) {
  const s = String(v ?? '')
  return /** @type {'day' | '3day' | 'week' | 'month'} */ (CAL_DESK_VIEWS.includes(s) ? s : 'week')
}

/**
 * Spec 170 section 11.2: the view kind named by a route query. `?k=todo` is
 * the To-do view; anything else is the event views, never an error. Its own
 * key, because an unknown ?v= opens Week (calDeskView).
 * @param {{ k?: unknown } | null | undefined} query
 * @returns {'todo' | 'events'}
 */
export function calTodoKind(query) {
  return String(query?.k ?? '') === 'todo' ? 'todo' : 'events'
}

/**
 * Spec 170 row B2: the days the To-do view lists for a range, as [from, to).
 * Day, 3 days and Week are calDeskRange's; Month is the month of `iso` only,
 * not the 6x7 grid's days of the months around it. null when not a day.
 * @param {string} view
 * @param {string} iso
 * @returns {{ from: string, to: string } | null}
 */
export function calTodoRange(view, iso) {
  if (view !== 'month') return calDeskRange(view, iso)
  if (Number.isNaN(calDayMs(iso))) return null
  const y = Number(iso.slice(0, 4))
  const m = Number(iso.slice(5, 7))
  const next = m === 12 ? `${y + 1}-01-01` : `${iso.slice(0, 4)}-${String(m + 1).padStart(2, '0')}-01`
  return { from: `${iso.slice(0, 7)}-01`, to: next }
}

/**
 * The days a view shows: Day is `iso`, 3 days the day before, `iso` and
 * the day after (owner msg 37951fb6), Week Monday..Sunday of `iso`, Month
 * its 6x7 Monday-first grid. [] when not a day.
 * @param {string} view
 * @param {string} iso
 * @returns {string[]}
 */
export function calDeskDays(view, iso) {
  if (Number.isNaN(calDayMs(iso))) return []
  if (view === 'day') return [iso]
  if (view === '3day') return [calAddDays(iso, -1), iso, calAddDays(iso, 1)]
  if (view === 'month') return calPhoneMonthGrid(iso).map((c) => c.iso)
  return calWeekDays(iso)
}

/**
 * The days a view reads, as [from, to). null when not a day.
 * @param {string} view
 * @param {string} iso
 * @returns {{ from: string, to: string } | null}
 */
export function calDeskRange(view, iso) {
  const days = calDeskDays(view, iso)
  if (!days.length) return null
  return { from: days[0], to: calAddDays(days[days.length - 1], 1) }
}

/**
 * The focus day one period on (`dir` 1) or back (-1): a day, three days, a
 * week or a month (the day of the month kept, clamped). '' when not a day.
 * @param {string} view
 * @param {string} iso
 * @param {number} dir
 * @returns {string}
 */
export function calDeskStep(view, iso, dir) {
  if (Number.isNaN(calDayMs(iso))) return ''
  if (view === '3day') return calAddDays(iso, 3 * Math.sign(Number(dir) || 0))
  return calPhoneStep(view === 'day' || view === 'month' ? view : 'week', iso, dir)
}

/**
 * The period title: one day, or the first and last day shown; a month as
 * YYYY-MM (dates are YYYY-MM-DD in every UI locale, utils/date-iso.mjs).
 * @param {string} view
 * @param {string} iso
 * @returns {string[]} one or two lines
 */
export function calDeskTitle(view, iso) {
  const days = calDeskDays(view, iso)
  if (!days.length) return []
  if (view === 'month') return [iso.slice(0, 7)]
  if (days.length === 1) return [days[0]]
  return [days[0], days[days.length - 1]]
}

/**
 * The height of one hour row: the grid's visible height over the 8-hour
 * window, never under CAL_DESK_MIN_HOUR_PX.
 * @param {number} visiblePx the scroller's height below the day heads
 * @returns {number}
 */
export function calDeskHourPx(visiblePx) {
  const px = Number(visiblePx) / CAL_DESK_WINDOW_H
  return Number.isFinite(px) ? Math.max(CAL_DESK_MIN_HOUR_PX, Math.floor(px)) : CAL_DESK_MIN_HOUR_PX
}

/** A timed event this long or longer is a bar in the all-day strip (SPL-6491). */
const CAL_DESK_BAR_MS = 24 * 60 * 60 * 1000

/**
 * SPL-6491: true when the desktop time grid cannot hold `ev` and it is drawn
 * as a bar in the all-day strip instead: it covers more than one day
 * (calPhoneEventDays: all-day by UTC date, timed by the wall days of `zone`
 * it touches, an end at 00:00 not counting), or it is timed and lasts 24 h
 * or more (a 25 h day of a DST change covers one wall day).
 * @param {{ starts_at?: string, ends_at?: string, all_day?: boolean }} ev
 * @param {string} [zone] '' is the viewer's
 * @returns {boolean}
 */
export function calDeskSpans(ev, zone = '') {
  if (calPhoneEventDays(ev, zone).length > 1) return true
  if (!ev || ev.all_day) return false
  return Date.parse(String(ev.ends_at)) - Date.parse(String(ev.starts_at)) >= CAL_DESK_BAR_MS
}

/**
 * SPL-6491: the all-day strip's bars over the shown `days`. Each spanning
 * event (calDeskSpans) that covers a shown day is one bar from its first to
 * its last shown day (`from`, `to`: indexes into `days`), cut at the range:
 * `before` / `after` say it goes on past the first / last shown day. Bars
 * take the first lane free over their days, earliest and longest first, so
 * no two in one lane overlap; `lanes` is how many the strip needs.
 * @template {{ id: string, starts_at: string, ends_at?: string, all_day?: boolean, pinned?: boolean }} T
 * @param {T[]} items
 * @param {string[]} days the shown days, oldest first
 * @param {string} [zone] '' is the viewer's
 * @returns {{ bars: { ev: T, from: number, to: number, lane: number, before: boolean, after: boolean }[], lanes: number }}
 */
export function calDeskBars(items, days, zone = '') {
  const at = new Map(days.map((d, i) => [d, i]))
  const bars = []
  for (const ev of items || []) {
    if (!calDeskSpans(ev, zone)) continue
    const covered = calPhoneEventDays(ev, zone)
    const idx = covered.map((d) => at.get(d)).filter((i) => i !== undefined)
    if (!idx.length) continue
    const from = Math.min(...idx)
    const to = Math.max(...idx)
    bars.push({ ev, from, to, lane: 0, before: covered[0] < days[from], after: covered[covered.length - 1] > days[to] })
  }
  bars.sort((a, b) => a.from - b.from || (b.to - b.from) - (a.to - a.from) || calDayCompare(a.ev, b.ev, true, true))
  /** @type {number[]} the last day index each lane holds */
  const ends = []
  for (const b of bars) {
    let lane = ends.findIndex((end) => end < b.from)
    if (lane < 0) lane = ends.length
    ends[lane] = b.to
    b.lane = lane
  }
  return { bars, lanes: ends.length }
}

/**
 * SPL-6491: the desktop Month's items per day: a spanning event (calDeskSpans)
 * on every day it covers, the rest on the day they start (calEventDay's
 * rule: an all-day one by UTC date, a timed one by the viewer's); each day in
 * the one order (calDayCompare), a spanning event with the whole-day ones.
 * @template {{ id: string, starts_at: string, ends_at?: string, all_day?: boolean, pinned?: boolean }} T
 * @param {T[]} items
 * @param {string} [zone] '' is the viewer's
 * @returns {Map<string, T[]>}
 */
export function calDeskByDay(items, zone = '') {
  const out = new Map()
  for (const ev of items || []) {
    const span = calDeskSpans(ev, zone)
    const days = calPhoneEventDays(ev, zone)
    for (const d of span ? days : days.slice(0, 1)) out.set(d, [...(out.get(d) || []), ev])
  }
  const whole = (ev) => !!ev.all_day || calDeskSpans(ev, zone)
  for (const list of out.values()) list.sort((a, b) => calDayCompare(a, b, whole(a), whole(b)))
  return out
}
