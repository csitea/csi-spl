/**
 * Spec 089 T006 (owner D4): a reminder is a plain in-app pop-up, Google
 * Calendar style. The app keeps its own timer: it asks the hub for the
 * viewer's reminders (GET /v1/calendar/reminders, spec 089 section 6.1),
 * and this file decides, from that list, the time now and the reminders the
 * person already dismissed, what to show now and when to look again.
 * No agent, no AI, no spool message: nothing here writes anywhere but the
 * browser's own localStorage.
 * Pure: node tests import it; plugins/calendar-reminders.client.ts wraps it.
 */

/** How far ahead the app asks for reminders (section 4.3: the next 24 hours). */
export const REMINDER_AHEAD_MS = 24 * 60 * 60 * 1000
/** How far back it asks, so a reminder missed while the app was closed still shows. */
export const REMINDER_BEHIND_MS = 24 * 60 * 60 * 1000
/** Ask again once an hour (section 4.3). */
export const REMINDER_REFRESH_MS = 60 * 60 * 1000
/** A focus within this gap of the last read does not read again. */
export const REMINDER_FOCUS_GAP_MS = 60 * 1000
/** localStorage: the dismissed reminders, `{ "<id>@<remind_at>": <remind ms> }`. */
export const REMINDER_DISMISSED_KEY = 'spool.calendar.dismissed'
/** A window event the calendar section fires after it creates, edits or deletes an event. */
export const CALENDAR_CHANGED_EVENT = 'spool:calendar-changed'
/** A dismissed key is forgotten this long after its reminder time. */
const KEEP_MS = 7 * 24 * 60 * 60 * 1000
const KEEP_MAX = 500

/** Milliseconds of an RFC 3339 time, NaN for "" or anything unparsable. */
function ms(v) {
  return typeof v === 'string' && v ? Date.parse(v) : NaN
}

/** The key a dismiss is remembered under: one event at one reminder time. */
export function reminderKey(ev) {
  return `${ev.id}@${ev.remind_at}`
}

/** The `from` / `to` of the reminders read at `now`. */
export function reminderWindow(now) {
  return { from: new Date(now - REMINDER_BEHIND_MS).toISOString(), to: new Date(now + REMINDER_AHEAD_MS).toISOString() }
}

/**
 * The usable reminders of a `GET /v1/calendar/reminders` answer: `event`
 * items with an id and a parsable `remind_at`, oldest reminder first.
 * Anything else in the body is ignored, never thrown on.
 */
export function readReminders(body) {
  const list = body && Array.isArray(body.reminders) ? body.reminders : []
  const out = []
  for (const ev of list) {
    if (!ev || typeof ev !== 'object') continue
    if (ev.source !== undefined && ev.source !== 'event') continue
    if (typeof ev.id !== 'string' || !ev.id || Number.isNaN(ms(ev.remind_at))) continue
    out.push({
      id: ev.id,
      title: typeof ev.title === 'string' ? ev.title : '',
      starts_at: typeof ev.starts_at === 'string' ? ev.starts_at : '',
      ends_at: typeof ev.ends_at === 'string' ? ev.ends_at : '',
      all_day: ev.all_day === true,
      remind_at: ev.remind_at,
    })
  }
  return out.sort((a, b) => ms(a.remind_at) - ms(b.remind_at) || a.id.localeCompare(b.id))
}

/** The dismissed map from its stored text; old and malformed entries dropped. */
export function parseDismissed(raw, now) {
  let obj = null
  try { obj = JSON.parse(String(raw || '')) } catch { obj = null }
  const out = {}
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return out
  const keep = Object.entries(obj)
    .filter(([k, v]) => k.includes('@') && Number.isFinite(v) && v > now - KEEP_MS)
    .sort((a, b) => b[1] - a[1])
    .slice(0, KEEP_MAX)
  for (const [k, v] of keep) out[k] = v
  return out
}

/** The dismissed map with `ev` added. */
export function withDismissed(dismissed, ev) {
  const at = ms(ev.remind_at)
  return { ...dismissed, [reminderKey(ev)]: Number.isNaN(at) ? 0 : at }
}

/**
 * What to show at `now`: `show` = the reminders that are due (their time has
 * come), not dismissed, and whose event has not ended (a missed reminder
 * shows once the app opens, until the event is over); `next` = the
 * milliseconds until the next reminder comes, -1 when none is left in the list.
 */
export function dueReminders(list, now, dismissed) {
  const show = []
  let next = -1
  for (const ev of Array.isArray(list) ? list : []) {
    if (dismissed && Object.prototype.hasOwnProperty.call(dismissed, reminderKey(ev))) continue
    const at = ms(ev.remind_at)
    if (Number.isNaN(at)) continue
    if (at > now) {
      if (next < 0 || at - now < next) next = at - now
      continue
    }
    const end = ms(ev.ends_at)
    if (!Number.isNaN(end) && end <= now) continue
    show.push(ev)
  }
  return { show, next }
}
