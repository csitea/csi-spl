// spec 097 T013 (G1, spec 5.1.1): drag to move, drag the bottom edge to
// resize, drag on empty time to create - the pure half. CalendarMainView.vue
// holds the pointers; this turns a day and a minute of that day into the
// PATCH body, and lays a day's timed events out on its time grid.
//
// Minutes are the VIEWER's wall clock (utils/date-iso), the zone every
// calendar clock prints in; calWallToUtc turns one back into an instant. A
// move keeps the event's length in real time; a step is 15 minutes. An
// all-day event moves by whole UTC days and keeps its `T00:00:00Z` form.

import { isoClock, isoDate } from './date-iso.mjs'
import { calAddDays, calDayMs } from './calendar-year.mjs'
import { calWallToUtc } from './calendar-event-form.mjs'
import { isoSeconds } from './iso-seconds.mjs'

export const CAL_SNAP_MIN = 15
export const CAL_DAY_MIN = 24 * 60
/** a touch held this long lifts the event (or starts a new one); shorter is a tap or a scroll */
export const CAL_HOLD_MS = 250
/** a mouse moved this far is a drag, not a click */
export const CAL_DRAG_PX = 4
/** a finger moved this far before the hold ends is a scroll */
export const CAL_TOUCH_SLOP_PX = 8

const pad = (n) => String(n).padStart(2, '0')
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v))

/** `HH:MM` of a minute of the day (0..1439). */
export function calHhmm(min) {
  const m = clamp(Math.round(min), 0, CAL_DAY_MIN - 1)
  return `${pad(Math.floor(m / 60))}:${pad(m % 60)}`
}

/** The minute of the day of an instant, in the viewer's zone (NaN when not one). */
export function calMinuteOf(value) {
  const c = isoClock(value)
  return c ? Number(c.slice(0, 2)) * 60 + Number(c.slice(3)) : Number.NaN
}

/** `min` to the nearest 15 minutes, inside [lo, hi]. */
export function calSnap(min, lo = 0, hi = CAL_DAY_MIN) {
  return clamp(Math.round(min / CAL_SNAP_MIN) * CAL_SNAP_MIN, lo, hi)
}

/** The instant of `day` at minute `min`; 1440 is the next day's 00:00. */
function wallAt(day, min) {
  return min >= CAL_DAY_MIN ? calWallToUtc(calAddDays(day, 1), '00:00') : calWallToUtc(day, calHhmm(min))
}

/** The event's day on the grid: its UTC day when all day, else the viewer's. */
export function calEventDay(ev) {
  return ev.all_day ? String(ev.starts_at || '').slice(0, 10) : isoDate(ev.starts_at)
}

/**
 * `ev` moved to `day`, starting at minute `startMin` (null keeps its clock:
 * the Week list moves between days only). Its length stays. null when the
 * times cannot be read.
 * @returns {{ starts_at: string, ends_at: string } | null}
 */
export function calMoveTo(ev, day, startMin = null) {
  const s = Date.parse(ev.starts_at)
  const e = Date.parse(ev.ends_at)
  if (Number.isNaN(s) || Number.isNaN(calDayMs(day))) return null
  if (ev.all_day) {
    const shift = Math.round((calDayMs(day) - calDayMs(calEventDay(ev))) / 86400000)
    const endDay = Number.isNaN(e) ? calAddDays(day, 1) : calAddDays(String(ev.ends_at).slice(0, 10), shift)
    return { starts_at: `${day}T00:00:00Z`, ends_at: `${endDay}T00:00:00Z` }
  }
  const len = Number.isNaN(e) ? 0 : Math.max(0, e - s)
  const min = startMin === null ? calMinuteOf(ev.starts_at) : startMin
  const startsAt = wallAt(day, clamp(min, 0, CAL_DAY_MIN - CAL_SNAP_MIN))
  if (!startsAt) return null
  return { starts_at: startsAt, ends_at: isoSeconds(new Date(Date.parse(startsAt) + len)) }
}

/**
 * `ev` with its end at minute `endMin` of its start day (1440 = midnight
 * after), never shorter than 15 minutes. null for an all-day event.
 * @returns {{ starts_at: string, ends_at: string } | null}
 */
export function calResizeTo(ev, endMin) {
  if (ev.all_day) return null
  const day = isoDate(ev.starts_at)
  const start = calMinuteOf(ev.starts_at)
  if (!day || Number.isNaN(start)) return null
  const endsAt = wallAt(day, clamp(endMin, start + CAL_SNAP_MIN, CAL_DAY_MIN))
  return endsAt ? { starts_at: ev.starts_at, ends_at: endsAt } : null
}

/** The `{start, end}` (HH:MM) a drag on empty time from minute `a` to `b` makes; a plain hold is one hour. */
export function calCreateSlot(a, b) {
  let lo = Math.min(a, b)
  let hi = Math.max(a, b)
  if (hi - lo < CAL_SNAP_MIN) hi = lo + 60
  lo = clamp(lo, 0, CAL_DAY_MIN - 2 * CAL_SNAP_MIN)
  hi = clamp(hi, lo + CAL_SNAP_MIN, CAL_DAY_MIN - 1)
  return { start: calHhmm(lo), end: calHhmm(hi) }
}

/** True when `next` moves nothing (same start and end instants). */
export function calSameTimes(ev, next) {
  return Date.parse(ev.starts_at) === Date.parse(next.starts_at) && Date.parse(ev.ends_at) === Date.parse(next.ends_at)
}

/**
 * The timed events of one day on its grid: `top` and `len` in minutes (cut
 * at midnight, at least 15), and the column `col` of `cols` that keeps
 * overlapping events side by side.
 * @template {{ starts_at: string, ends_at: string, id: string }} T
 * @param {T[]} events the day's timed events
 * @returns {{ ev: T, top: number, len: number, col: number, cols: number }[]}
 */
export function calDayLayout(events) {
  const boxes = events
    .map((ev) => {
      const top = calMinuteOf(ev.starts_at)
      const lenMs = Date.parse(ev.ends_at) - Date.parse(ev.starts_at)
      const len = Number.isNaN(lenMs) ? 0 : lenMs / 60000
      return { ev, top, len: clamp(len, CAL_SNAP_MIN, CAL_DAY_MIN - top), col: 0, cols: 1 }
    })
    .filter((b) => !Number.isNaN(b.top))
    .sort((x, y) => x.top - y.top || y.len - x.len || String(x.ev.id).localeCompare(String(y.ev.id)))
  /* a cluster is a run of boxes that overlap one after another; each takes
     the first column free at its start, the cluster is as wide as its columns */
  let cluster = []
  let ends = []
  let clusterEnd = -1
  const close = () => {
    for (const b of cluster) b.cols = ends.length
    cluster = []
    ends = []
  }
  for (const b of boxes) {
    if (b.top >= clusterEnd) close()
    let col = ends.findIndex((end) => end <= b.top)
    if (col < 0) col = ends.length
    ends[col] = b.top + b.len
    b.col = col
    cluster.push(b)
    clusterEnd = Math.max(clusterEnd, b.top + b.len)
  }
  close()
  return boxes
}

/**
 * The i18n key (calendar_event.*) for a refused drag: the dialog's words for
 * the same refusals, and `drag_conflict` for 409 edit_conflict.
 * @param {{ status?: number, token?: string } | null | undefined} e
 */
export function calDragErrorKey(e) {
  const code = Number(e?.status) || 0
  const why = String(e?.token || '')
  if (code === 409 || why === 'edit_conflict') return 'calendar_event.drag_conflict'
  if (code === 401) return 'calendar_event.error_signed_out'
  if (why === 'private_owner_only') return 'calendar_event.error_private_owner'
  if (why === 'demo_read_only') return 'calendar_event.error_demo'
  if (code === 403) return 'calendar_event.error_forbidden'
  if (code === 404) return 'calendar_event.error_not_found'
  if (code === 400) return 'calendar_event.error_bad'
  return 'calendar_event.error_save'
}
