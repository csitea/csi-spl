// SPL-4060 (owner HUM-10, t1 080e1f77, poll 7c472af4): the desktop
// calendar's views, pure. The vertical tab group at the grid's left edge
// picks one of Day, 3 days, Week and Month; this answers which days each
// shows around the focus day, the [from, to) it reads, where previous /
// next go and how tall an hour row is so 8 hours are on screen at once.
//
// Days are 'YYYY-MM-DD' (calendar-year.mjs). Names carry "calDesk" because
// Nuxt auto-imports every utils export.

import { calAddDays, calDayMs, calWeekDays } from './calendar-year.mjs'
import { calPhoneMonthGrid, calPhoneStep } from './calendar-phone-nav.mjs'

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
