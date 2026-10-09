/**
 * The public calendar's hub source (rdb 0158, owner t1 a3ce2031): the
 * workspace's `web` events, the one audience meant for the internet, from
 * the signed-out GET /v1/public/calendar/events?start=&end= (hub
 * calendar_web.go). The hub answers only title, description, start, end and
 * all day; no id, no link, no people. pages/public-calendar.vue imports this
 * module on mount, so none of it rides the initial JS (ci_initial_gzip_kb).
 *
 * The rows are publicCalendarEvent's `web` kind: a timed event on the
 * viewer's day and clock (utils/date-iso-zone, the zone every calendar clock
 * prints in), an all-day one on its UTC day as the hub stores it. An event
 * over several days shows on its first.
 */

import { isoDateTimeIn } from './date-iso-zone.mjs'
import { DOC_READ_TIMEOUT_MS } from './fetch-timeouts.mjs'
import { isoSeconds } from './iso-seconds.mjs'

export const PUBLIC_CALENDAR_WEB_PATH = '/v1/public/calendar/events'

/**
 * The range one shown month (`YYYY-MM`) reads: a day either side of its UTC
 * days, so an event the viewer's zone moves into the month is read too
 * (pubCalMonthDays keeps only the month's own days).
 * @param {string} month
 * @returns {{ start: string, end: string }}
 */
export function pubCalWebRange(month) {
  const [y, m] = String(month).split('-').map(Number)
  return { start: isoSeconds(new Date(Date.UTC(y, m - 1, 0))), end: isoSeconds(new Date(Date.UTC(y, m, 2))) }
}

/**
 * The hub's answer as `web` rows (publicCalendarEvent drops a bad one).
 * @param {{ events?: unknown[] } | null | undefined} body
 */
export function webCalendarRows(body) {
  const out = []
  for (const e of Array.isArray(body && body.events) ? body.events : []) {
    const r = /** @type {Record<string, unknown>} */ (e || {})
    const startsAt = String(r.starts_at || '')
    const t = Date.parse(startsAt)
    if (Number.isNaN(t)) continue
    const allDay = r.all_day === true
    const from = allDay ? '' : isoDateTimeIn(startsAt, '')
    const to = allDay ? '' : isoDateTimeIn(String(r.ends_at || ''), '')
    out.push({
      kind: 'web',
      day: allDay ? startsAt.slice(0, 10) : from.slice(0, 10),
      at: startsAt,
      title: String(r.title || ''),
      description: String(r.description || ''),
      allDay,
      from: from.slice(11),
      to: to.slice(11),
    })
  }
  return out
}

/**
 * The web rows of one shown month. The mock workspace answers from
 * calendar-mock (its `web` events); the hub is read without a session.
 * Throws on a refusal (the page then shows the build's events only).
 * @param {{ base?: string, mock?: boolean }} api useSpoolApi()
 * @param {string} month `YYYY-MM`
 * @param {string} todayIso `YYYY-MM-DD`
 */
export async function fetchWebCalendar(api, month, todayIso) {
  const { start, end } = pubCalWebRange(month)
  if (api && api.mock) {
    const { mockWebCalendarEvents } = await import('./calendar-mock.mjs')
    return webCalendarRows(mockWebCalendarEvents(start, end, todayIso))
  }
  const q = new URLSearchParams({ start, end })
  const r = await fetch(`${String((api && api.base) || '')}${PUBLIC_CALENDAR_WEB_PATH}?${q}`, {
    credentials: 'omit', headers: { accept: 'application/json' }, signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS),
  })
  if (!r.ok) throw Object.assign(new Error(`public calendar ${r.status}`), { status: r.status })
  return webCalendarRows(await r.json())
}
