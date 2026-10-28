// spec 089 T008 v1 (owner msg 72db6282, "a bit more simple than the google
// calendar"): the event dialog's form, pure. CalendarEventDialog.vue holds the
// fields; this turns an event into them and them back into the body of
// POST /v1/calendar/events or PATCH /v1/calendar/events/{id} (spec 6.1.2).
//
// A timed event's date and clock are the VIEWER's wall time (utils/date-iso),
// the zone every calendar clock prints in; an all-day event is whole UTC days
// [D 00:00Z, D+1 00:00Z), as the hub stores official days. Audience: the
// Private switch off is `workspace` (089 4.2, the default: everyone in the
// workspace), on is `private`; an `internal` event keeps `internal` while
// the switch is not moved (v1 does not offer `internal`, the field stays).
// The Public switch (rdb 0158, owner t1 a3ce2031) shows the event to
// signed-out visitors on /public-calendar. It is never on by default - a new
// event, a Duplicate (calFormCopy, even of a public event) and an event of
// another audience open with it off - and Private wins over it, so a form
// with both on never sends the public audience.
//
// The rename (owner t1 a3ce2031 msg bad3799a, the docs' naming; rdb 0159):
// workspace was called `public`, and public was called `web`. This form
// sends `public` (CAL_PUBLIC_WIRE; the hub's step 4 takes it, step 5's rdb
// 0161 holds no `web` row any more) and still reads `web` as public
// (calIsPublic), the name a hub before step 4 sent.
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
/** SPL-4043: an event links at most this many issues, each key at most 32 runes. */
export const CAL_ISSUE_KEYS_MAX = 20
/** The hub's palette (spec 3.3); "" is the kind's own colour. */
export const CAL_COLORS = ['tomato', 'flamingo', 'tangerine', 'banana', 'sage', 'basil', 'peacock', 'blueberry', 'lavender', 'grape', 'graphite']
/** A reminder's unit and its largest amount: 4 weeks before (spec 4.3). */
export const CAL_REMINDER_UNITS = { minutes: 40320, hours: 672, days: 28 }

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/
const TOPIC_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const TOPIC_SHORT = /^[0-9a-f]{8}$/
const TOPIC_LINK = /\/t\/([0-9a-f]{8}(?:-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?)(?:[^0-9a-f-]|$)/
const ISSUE_PREFIX = /^[A-Za-z][A-Za-z0-9]{0,9}$/
const ISSUE_NUM = /^[1-9][0-9]*$/
const HUM_ID = /^HUM-[0-9]+$/
const AGENT_BARE = /^(?:[acgmq]-[0-9]{3,}|(?:CLE|AGY|GRK|QWN)-[0-9]+)$/
const AGENT_ID = /^(?:[acgmq]-[0-9]{3,}|(?:CLE|AGY|GRK|QWN)-[0-9]+)(?:@[A-Za-z0-9][A-Za-z0-9._-]*)?$/
const pad = (n) => String(n).padStart(2, '0')

/**
 * SPL-4043: a topic id, its 8-hex short id, or a link carrying /t/<either>,
 * lower-cased. '' when the text is empty or none of those.
 * @param {unknown} input
 */
export function calDiscussionRef(input) {
  const v = String(input ?? '').trim().toLowerCase()
  if (!v) return ''
  if (TOPIC_ID.test(v) || TOPIC_SHORT.test(v)) return v
  const m = TOPIC_LINK.exec(v)
  return m ? m[1] : ''
}

/**
 * One issue key as the hub's ParseIssueRef accepts it ("SPL-12", "spl-12" or
 * "12"), or '' when it is not one. At most 32 runes.
 * @param {unknown} raw
 */
export function calIssueKey(raw) {
  const s = String(raw ?? '').trim()
  if (!s || [...s].length > 32) return ''
  const i = s.lastIndexOf('-')
  if (i < 0) return ISSUE_NUM.test(s) ? s : ''
  if (!ISSUE_PREFIX.test(s.slice(0, i)) || !ISSUE_NUM.test(s.slice(i + 1))) return ''
  return s
}

/** The keys, trimmed, valid, first spelling kept, later copies of the same key dropped. */
export function calIssueKeys(list) {
  const out = []
  for (const raw of list || []) {
    const k = calIssueKey(raw)
    if (!k || out.some((x) => x.toLowerCase() === k.toLowerCase())) continue
    out.push(k)
  }
  return out
}

/**
 * '' when empty (the hub then keeps the creator), the id when it is a member
 * or an agent, null when the text is neither.
 * @param {unknown} raw
 * @returns {string | null}
 */
export function calOwnerId(raw) {
  const s = String(raw ?? '').trim()
  if (!s) return ''
  return HUM_ID.test(s) || AGENT_ID.test(s) ? s : null
}

/**
 * Owner choices for the picker: member ids, then agent ids (`id` or `id@box`).
 * @param {Record<string, unknown> | null | undefined} humans
 * @param {{ id?: string, box?: string }[] | null | undefined} people
 */
export function calOwnerChoices(humans, people) {
  const out = []
  const seen = new Set()
  const add = (id) => {
    if (!id || seen.has(id)) return
    seen.add(id)
    out.push(id)
  }
  for (const id of Object.keys(humans && typeof humans === 'object' ? humans : {})) {
    if (HUM_ID.test(id)) add(id)
  }
  for (const p of people || []) {
    const id = String((p && p.id) || '')
    const box = String((p && p.box) || '')
    if (!AGENT_BARE.test(id)) continue
    add(box ? `${id}@${box}` : id)
  }
  return out
}

/**
 * Discussion, issue keys and owner for a save, or `{ error }` with an i18n key.
 * @param {{ discussion?: string, issueKeys?: unknown[], owner?: string } | null | undefined} form
 * @returns {{ topic_id: string, issue_keys: string[], owner_id: string } | { error: string }}
 */
function calLinksOf(form) {
  const discussion = String((form && form.discussion) || '').trim()
  const topicId = discussion ? calDiscussionRef(discussion) : ''
  if (discussion && !topicId) return { error: 'calendar_event.error_discussion' }
  const raw = (Array.isArray(form && form.issueKeys) ? form.issueKeys : []).map((k) => String(k ?? '').trim()).filter(Boolean)
  if (raw.length > CAL_ISSUE_KEYS_MAX) return { error: 'calendar_event.error_issue_many' }
  if (raw.some((k) => !calIssueKey(k))) return { error: 'calendar_event.error_issue' }
  const owner = calOwnerId(form && form.owner)
  if (owner === null) return { error: 'calendar_event.error_owner' }
  return { topic_id: topicId, issue_keys: calIssueKeys(raw), owner_id: owner }
}

/** A stored event (source `event`): it opens its pop-over; an issue deadline and an official day do not. */
export function calStored(ev) {
  return Boolean(ev && ev.id && (ev.source || 'event') === 'event')
}

/**
 * specs/112 WUI-2 (4.1, 4.4): an event the roadmap sync wrote carries its
 * `source_key` (goal:, spec:, release:, db:); it is changed in the repo, and
 * the hub answers a PATCH or DELETE of it 409 `synced_read_only`.
 */
export function calSynced(ev) {
  return Boolean(ev && ev.source_key)
}

/** SPL-2034: an issue deadline (source `issue`); it opens a read-only pop-over, never the editor. */
export function calDeadline(ev) {
  return Boolean(ev && ev.id && ev.source === 'issue')
}

/** Only a member's stored event is edited here: not a synced one, an issue deadline or an official day. */
export function calEditable(ev) {
  return calStored(ev) && !calSynced(ev)
}

/**
 * A synced event's roadmap link, `props.roadmap_url` as the sync wrote it
 * (never built here), or '' unless it is a path of this site.
 */
export function calRoadmapHref(ev) {
  const href = String((ev && ev.roadmap_url) || '')
  return href.startsWith('/') && !href.startsWith('//') ? href : ''
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
      timeZone, zoneWas: timeZone, location: '', reminders: [], color: '', private: false, public: false, description: '',
      discussion: '', issueKeys: [], owner: '',
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
    public: calIsPublic(ev),
    description: String(ev.description || ''),
    discussion: String(ev.topic_id || ''),
    issueKeys: calIssueKeys(Array.isArray(ev.issue_keys) ? ev.issue_keys : []),
    owner: String(ev.owner_id || ''),
  }
}

/**
 * Duplicate (G11): the form of `ev` for a new event, every field kept but
 * the Public switch - the internet sees an event only when someone chose it.
 */
export function calFormCopy(ev, day) {
  return { ...calFormFromEvent(ev, day), public: false }
}

/** The public audience as this WUI sends it (the rename's step 5; it was `web`). */
export const CAL_PUBLIC_WIRE = 'public'

/** `ev` is shown to signed-out visitors: audience `public`, or `web` (its name before the rename). */
export function calIsPublic(ev) {
  return Boolean(ev) && (ev.audience === 'public' || ev.audience === 'web')
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

/** The audience the switches mean for `ev` (null = a new event); a public event left public keeps its stored name. */
function audienceOf(form, ev) {
  if (form.private) return 'private'
  if (form.public) return calIsPublic(ev) ? ev.audience : CAL_PUBLIC_WIRE
  return ev && ev.audience && ev.audience !== 'private' && !calIsPublic(ev) ? ev.audience : 'workspace'
}

/**
 * The form after one of the two exclusive switches moved: Private on turns
 * Public off, Public on turns Private off.
 * @template {{ private: boolean, public: boolean }} F
 * @param {F} form
 * @param {'private' | 'public'} which
 * @returns {F}
 */
export function calAudienceSwitched(form, which) {
  if (which === 'private' && form.private) return { ...form, public: false }
  if (which === 'public' && form.public) return { ...form, private: false }
  return form
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
  const links = calLinksOf(form)
  if (links.error) return { error: links.error }
  const full = {
    title, starts_at: startsAt, ends_at: endsAt, all_day: Boolean(form.allDay), time_zone: zone || 'UTC',
    location, reminders, color, audience: audienceOf(form, ev), description,
    topic_id: links.topic_id, issue_keys: links.issue_keys, owner_id: links.owner_id,
  }
  if (!ev) return { body: full }
  const storedKeys = calIssueKeys(Array.isArray(ev.issue_keys) ? ev.issue_keys : [])
  const body = {}
  for (const [k, v] of Object.entries(full)) {
    const was = ev[k]
    const same = k === 'all_day' ? v === Boolean(was)
      : k === 'starts_at' || k === 'ends_at' ? Date.parse(v) === Date.parse(was)
        : k === 'time_zone' ? zone === String(form.zoneWas || '')
          : k === 'reminders' ? remindersKey(v) === remindersKey(calRemindersOf(ev))
            : k === 'issue_keys' ? v.length === storedKeys.length && v.every((x, i) => x === storedKeys[i])
              : k === 'topic_id' ? v === String(ev.topic_id || '')
                : k === 'owner_id' ? v === String(ev.owner_id || '')
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
