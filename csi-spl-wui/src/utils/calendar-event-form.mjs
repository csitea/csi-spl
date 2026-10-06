// spec 089 T008 v1 (owner msg 72db6282, "a bit more simple than the google
// calendar"): the event dialog's form, pure. CalendarEventDialog.vue holds the
// fields; this turns an event into them and them back into the body of
// POST /v1/calendar/events or PATCH /v1/calendar/events/{id} (spec 6.1.2).
//
// A timed event's date and clock are the VIEWER's wall time (utils/date-iso),
// the zone every calendar clock prints in; an all-day event is whole UTC days
// [D 00:00Z, D+1 00:00Z), as the hub stores official days. Audience: the
// Private switch off is `public` (089 4.2, the default), on is `private`; an
// `internal` event keeps `internal` while the switch is not moved (v1 does
// not offer `internal`, the field stays).
//
// spec 097 T014..T016 add fields here (time zone, location, guests, reminders,
// colour) in the order of 097 section 5: one key in calFormFromEvent, one
// entry in calFormBody's `full`.

import { isoClock, isoDate } from './date-iso.mjs'
import { calAddDays, calDayMs } from './calendar-year.mjs'
import { isoSeconds } from './iso-seconds.mjs'

export const CAL_TITLE_MAX = 200
export const CAL_DESCRIPTION_MAX = 4000

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/
const pad = (n) => String(n).padStart(2, '0')

/** Only a stored event (source `event`) is edited here: an issue deadline and an official day are not. */
export function calEditable(ev) {
  return Boolean(ev && ev.id && (ev.source || 'event') === 'event')
}

/**
 * The Private switch shows to the event's creator only (FR-010; the hub's
 * `private_owner_only` is the rule, this only hides a choice it would refuse).
 * A new event is the viewer's own. An unknown viewer gets no switch.
 */
export function calCanSetPrivate(ev, viewerId) {
  if (!ev) return true
  const me = String(viewerId || '')
  return me !== '' && String(ev.creator_id || '') === me
}

/* ms of a YYYY-MM-DD HH:MM read as if it were UTC (NaN when not one) */
function wallMs(date, hhmm) {
  if (Number.isNaN(calDayMs(date)) || !HHMM.test(String(hhmm))) return Number.NaN
  return calDayMs(date) + (Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3))) * 60000
}

/**
 * The instant whose wall clock in the viewer's zone is `date` `hhmm`, as
 * RFC 3339 UTC; "" when either is not one. Two corrections cover a zone's
 * offset and a DST step (a wall time a spring step skips lands after it).
 */
export function calWallToUtc(date, hhmm) {
  const want = wallMs(date, hhmm)
  if (Number.isNaN(want)) return ''
  let t = want
  for (let i = 0; i < 2; i++) {
    const seen = wallMs(isoDate(t), isoClock(t))
    if (Number.isNaN(seen)) return ''
    t += want - seen
  }
  return isoSeconds(new Date(t))
}

/**
 * The form for `ev`, or for a new event on `day` (YYYY-MM-DD) when `ev` is
 * null: 09:00-10:00, public. `endDays` keeps a stored event's end on its own
 * day, so saving a two-day event does not shorten it (v1 has one date field).
 */
export function calFormFromEvent(ev, day) {
  if (!ev) {
    return { title: '', date: day, start: '09:00', end: '10:00', allDay: false, endDays: 0, private: false, description: '' }
  }
  const allDay = Boolean(ev.all_day)
  const date = allDay ? String(ev.starts_at || '').slice(0, 10) : isoDate(ev.starts_at)
  const endDate = allDay ? calAddDays(String(ev.ends_at || '').slice(0, 10), -1) : isoDate(ev.ends_at)
  const endDays = Math.max(0, Math.round((calDayMs(endDate) - calDayMs(date)) / 86400000) || 0)
  const start = allDay ? '09:00' : isoClock(ev.starts_at) || '09:00'
  const end = allDay ? '10:00' : isoClock(ev.ends_at) || start
  return {
    title: String(ev.title || ''),
    date,
    start,
    end,
    allDay,
    endDays,
    private: ev.audience === 'private',
    description: String(ev.description || ''),
  }
}

/** The audience the switch means for `ev` (null = a new event). */
function audienceOf(form, ev) {
  if (form.private) return 'private'
  return ev && ev.audience && ev.audience !== 'private' ? ev.audience : 'public'
}

/**
 * The request body, or { error } with an i18n key under calendar_event.*.
 * For a create (`ev` null) the whole event; for an edit only the fields that
 * changed, and `audience` only when it changed, so a non-creator's save never
 * sends it. `{ body: null }` is an edit that changes nothing.
 * @returns {{ body: Record<string, unknown> | null, error?: undefined } | { error: string, body?: undefined }}
 */
export function calFormBody(form, ev = null) {
  const title = String(form.title || '').trim()
  if (!title) return { error: 'calendar_event.error_title' }
  if ([...title].length > CAL_TITLE_MAX) return { error: 'calendar_event.error_title_long' }
  const description = String(form.description || '')
  if ([...description].length > CAL_DESCRIPTION_MAX) return { error: 'calendar_event.error_description_long' }
  if (Number.isNaN(calDayMs(form.date))) return { error: 'calendar_event.error_date' }
  const endDays = Math.max(0, Number(form.endDays) || 0)
  let startsAt
  let endsAt
  if (form.allDay) {
    startsAt = `${form.date}T00:00:00Z`
    endsAt = `${calAddDays(form.date, endDays + 1)}T00:00:00Z`
  } else {
    startsAt = calWallToUtc(form.date, form.start)
    endsAt = calWallToUtc(calAddDays(form.date, endDays), form.end)
    if (!startsAt || !endsAt) return { error: 'calendar_event.error_time' }
    if (Date.parse(endsAt) < Date.parse(startsAt)) return { error: 'calendar_event.error_end' }
  }
  const full = { title, starts_at: startsAt, ends_at: endsAt, all_day: Boolean(form.allDay), audience: audienceOf(form, ev), description }
  if (!ev) return { body: full }
  const body = {}
  for (const [k, v] of Object.entries(full)) {
    const was = ev[k]
    const same = k === 'all_day' ? v === Boolean(was)
      : k === 'starts_at' || k === 'ends_at' ? Date.parse(v) === Date.parse(was)
        : v === String(was ?? '')
    if (!same) body[k] = v
  }
  return { body: Object.keys(body).length ? body : null }
}

/** `HH:MM` one hour after `hhmm`, capped at 23:59 (a new start moves the end with it). */
export function calHourAfter(hhmm) {
  if (!HHMM.test(String(hhmm))) return hhmm
  const m = Math.min(23 * 60 + 59, Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3)) + 60)
  return `${pad(Math.floor(m / 60))}:${pad(m % 60)}`
}
