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
//
// 097 T014 (G6..G9, spec 4.1..4.3): the event's own time zone - the form's
// date and clock are wall time in it; a new event takes the member's
// `time_zone` preference (else the browser's), and an 089 event (stored
// `UTC`) opens in the viewer's zone and keeps `UTC` until the picker moves -
// a location, one of the hub's 11 colours, and up to 5 reminders, each a
// whole number 1 or more of minutes / hours / days, at most 4 weeks before
// (owner E2). Duplicate (G11) is calFormFromEvent of the source event, saved
// as a new one.

import { browserTimeZone, viewerTimeZone } from './date-iso.mjs'
import { isoDateTimeIn } from './date-iso-zone.mjs'
import { calAddDays, calDayMs } from './calendar-year.mjs'
import { isoSeconds } from './iso-seconds.mjs'

export const CAL_TITLE_MAX = 200
export const CAL_DESCRIPTION_MAX = 4000
export const CAL_LOCATION_MAX = 300
export const CAL_REMINDERS_MAX = 5
/** The hub's palette (spec 3.3); "" is the kind's own colour. */
export const CAL_COLORS = ['tomato', 'flamingo', 'tangerine', 'banana', 'sage', 'basil', 'peacock', 'blueberry', 'lavender', 'grape', 'graphite']
/** A reminder's unit and its largest amount: 4 weeks before (spec 4.3). */
export const CAL_REMINDER_UNITS = { minutes: 40320, hours: 672, days: 28 }

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
 * The instant whose wall clock in `zone` (the viewer's when "") is `date`
 * `hhmm`, as RFC 3339 UTC; "" when either is not one. Two corrections cover
 * a zone's offset and a DST step (a wall time a spring step skips lands after it).
 */
export function calWallToUtc(date, hhmm, zone = '') {
  const want = wallMs(date, hhmm)
  if (Number.isNaN(want)) return ''
  let t = want
  for (let i = 0; i < 2; i++) {
    const w = isoDateTimeIn(t, zone)
    const seen = wallMs(w.slice(0, 10), w.slice(11))
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
    const timeZone = calDefaultZone()
    return {
      title: '', date: day, start: '09:00', end: '10:00', allDay: false, endDays: 0,
      timeZone, zoneWas: timeZone, location: '', reminders: [], color: '', private: false, description: '',
    }
  }
  const allDay = Boolean(ev.all_day)
  const stored = String(ev.time_zone || '')
  const timeZone = stored && stored !== 'UTC' ? stored : calDefaultZone()
  const from = isoDateTimeIn(ev.starts_at, timeZone)
  const to = isoDateTimeIn(ev.ends_at, timeZone)
  const date = allDay ? String(ev.starts_at || '').slice(0, 10) : from.slice(0, 10)
  const endDate = allDay ? calAddDays(String(ev.ends_at || '').slice(0, 10), -1) : to.slice(0, 10)
  const endDays = Math.max(0, Math.round((calDayMs(endDate) - calDayMs(date)) / 86400000) || 0)
  const start = allDay ? '09:00' : from.slice(11) || '09:00'
  const end = allDay ? '10:00' : to.slice(11) || start
  return {
    title: String(ev.title || ''),
    date,
    start,
    end,
    allDay,
    endDays,
    timeZone,
    zoneWas: timeZone,
    location: String(ev.location || ''),
    reminders: calRemindersOf(ev).map((r) => ({ amount: String(r.amount), unit: r.unit })),
    color: CAL_COLORS.includes(ev.color) ? ev.color : '',
    private: ev.audience === 'private',
    description: String(ev.description || ''),
  }
}

/** A new event's zone: the member's `time_zone` preference, else the browser's, else UTC. */
export function calDefaultZone() {
  return viewerTimeZone() || browserTimeZone() || 'UTC'
}

/* an event's reminders as the hub sends them, each a known unit */
function calRemindersOf(ev) {
  const list = Array.isArray(ev && ev.reminders) ? ev.reminders : []
  return list.filter((r) => r && Object.hasOwn(CAL_REMINDER_UNITS, r.unit)).map((r) => ({ amount: Number(r.amount), unit: r.unit }))
}

/**
 * What a reminder's amount field keeps of a keystroke: digits only, no
 * leading zero, so a fraction, a sign or 0 cannot be typed (owner E2).
 */
export function calReminderAmount(raw) {
  return String(raw ?? '').replace(/\D+/g, '').replace(/^0+/, '').slice(0, 5)
}

/** "" for a good reminder row, else its i18n key: empty, or more than 4 weeks. */
export function calReminderError(row) {
  const n = Number(row && row.amount)
  if (!/^[1-9]\d*$/.test(String(row && row.amount))) return 'calendar_event.error_reminder_amount'
  if (!Object.hasOwn(CAL_REMINDER_UNITS, row.unit)) return 'calendar_event.error_reminder_amount'
  return n > CAL_REMINDER_UNITS[row.unit] ? 'calendar_event.error_reminder_max' : ''
}

/** The form's next reminder row: 10 minutes, or null when it holds 5 already. */
export function calNewReminder(rows) {
  return (rows || []).length >= CAL_REMINDERS_MAX ? null : { amount: '10', unit: 'minutes' }
}

/* the rows as the hub's list, equal ones once (it stores them once too) */
function remindersBody(rows) {
  const out = []
  for (const r of rows || []) {
    const x = { amount: Number(r.amount), unit: r.unit, method: 'popup' }
    if (!out.some((y) => y.amount === x.amount && y.unit === x.unit)) out.push(x)
  }
  return out
}
const remindersKey = (list) => list.map((r) => `${r.amount} ${r.unit}`).join(',')

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
  const location = String(form.location || '').trim()
  if ([...location].length > CAL_LOCATION_MAX) return { error: 'calendar_event.error_location_long' }
  const rows = form.reminders || []
  if (rows.length > CAL_REMINDERS_MAX) return { error: 'calendar_event.error_reminders_many' }
  const bad = rows.map(calReminderError).find(Boolean)
  if (bad) return { error: bad }
  const reminders = remindersBody(rows)
  const color = CAL_COLORS.includes(form.color) ? form.color : ''
  const zone = String(form.timeZone || '')
  const endDays = Math.max(0, Number(form.endDays) || 0)
  let startsAt
  let endsAt
  if (form.allDay) {
    startsAt = `${form.date}T00:00:00Z`
    endsAt = `${calAddDays(form.date, endDays + 1)}T00:00:00Z`
  } else {
    startsAt = calWallToUtc(form.date, form.start, zone)
    endsAt = calWallToUtc(calAddDays(form.date, endDays), form.end, zone)
    if (!startsAt || !endsAt) return { error: 'calendar_event.error_time' }
    if (Date.parse(endsAt) < Date.parse(startsAt)) return { error: 'calendar_event.error_end' }
  }
  const full = {
    title, starts_at: startsAt, ends_at: endsAt, all_day: Boolean(form.allDay), time_zone: zone || 'UTC',
    location, reminders, color, audience: audienceOf(form, ev), description,
  }
  if (!ev) return { body: full }
  const body = {}
  for (const [k, v] of Object.entries(full)) {
    const was = ev[k]
    const same = k === 'all_day' ? v === Boolean(was)
      : k === 'starts_at' || k === 'ends_at' ? Date.parse(v) === Date.parse(was)
        : k === 'time_zone' ? zone === String(form.zoneWas || '')
          : k === 'reminders' ? remindersKey(v) === remindersKey(calRemindersOf(ev))
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
