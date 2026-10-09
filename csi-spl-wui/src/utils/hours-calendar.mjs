/**
 * Spec 107 v1.2 T011 (owner R8..R11, t1 a28dc5c9): the member's hours inside
 * the calendar. Every working day shows one "Working hours" line with the
 * day's total; a click opens the event dialog of type Working hours (the
 * day's rows, its discussions as links); the calendar's right side carries
 * the hours tabs.
 *
 * The line is not a calendar event: it is drawn from GET /v1/me/hours?period=
 * (T006), one answer per period the shown range touches. Pure rules here,
 * loaded only by the calendar's lazy chunks (027); the fetch is
 * loadHoursRange, the mock workspace's answer hours-calendar-mock.mjs.
 */
import { isoDateTimeIn } from './date-iso-zone.mjs'

/** The dialog's entry type (the dialog's own, not a hub event kind). */
export const HOURS_ENTRY_TYPE = 'working_hours'
/** a range never needs more periods than this (a month view, weekly periods) */
export const HOURS_RANGE_MAX_PERIODS = 8

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/

function dayMs(iso) {
  return DAY_RE.test(String(iso || '')) ? Date.parse(`${iso}T00:00:00Z`) : Number.NaN
}

/** iso + n days, YYYY-MM-DD (UTC civil arithmetic, like calendar-year.mjs) */
export function hoursAddDays(iso, n) {
  const ms = dayMs(iso)
  return Number.isNaN(ms) ? '' : new Date(ms + n * 86400000).toISOString().slice(0, 10)
}

/** Monday..Friday of the civil date (spec 5.1). */
export function hoursIsWorkday(iso) {
  const ms = dayMs(iso)
  if (Number.isNaN(ms)) return false
  const wd = new Date(ms).getUTCDay()
  return wd >= 1 && wd <= 5
}

/** minutes as h:mm (never negative) */
export function hoursHhmm(min) {
  const m = Math.max(0, Math.round(Number(min) || 0))
  return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}`
}

/**
 * The day an answer's period ends + 1: the next period to ask for, or '' when
 * the answer has no usable period.
 * @param {{ period?: { end?: string } }} body
 */
export function hoursNextPeriodDay(body) {
  return hoursAddDays(String(body?.period?.end || ''), 1)
}

/**
 * Every period answer covering [first, last], asking `get(day)` for the
 * period holding `day` (GET /v1/me/hours?period=day). Stops at the range end,
 * at HOURS_RANGE_MAX_PERIODS, or when a period does not move forward.
 * @param {string} first
 * @param {string} last
 * @param {(day: string) => Promise<any>} get
 */
export async function hoursCollectPeriods(first, last, get) {
  const out = []
  let day = first
  for (let i = 0; i < HOURS_RANGE_MAX_PERIODS && day && day <= last; i++) {
    const body = await get(day)
    out.push(body)
    const next = hoursNextPeriodDay(body)
    if (!next || next <= day) break
    day = next
  }
  return out
}

/**
 * A row's minutes counted in the day's total: an approved entry or an open
 * suggestion; a rejected entry counts 0.
 * @param {{ state?: string, minutes?: number }} row
 */
export function hoursRowCounts(row) {
  return row && row.state !== 'rejected' ? Math.max(0, Number(row.minutes) || 0) : 0
}

/**
 * Per day: the day's answer with its total and its period, from one or more
 * GET /v1/me/hours bodies. Map<YYYY-MM-DD, HoursDay>.
 * @param {any[]} bodies
 */
export function hoursIndex(bodies) {
  const out = new Map()
  for (const b of Array.isArray(bodies) ? bodies : []) {
    if (!b || !Array.isArray(b.days)) continue
    const period = b.period && typeof b.period === 'object' ? b.period : null
    for (const d of b.days) {
      if (!d || !DAY_RE.test(String(d.date || ''))) continue
      const rows = Array.isArray(d.rows) ? d.rows : []
      const total = rows.reduce((n, r) => n + hoursRowCounts(r), 0)
      out.set(d.date, {
        date: d.date,
        today: Boolean(d.today),
        closed: Boolean(d.closed),
        frozen: Boolean(d.frozen),
        open: Math.max(0, Number(d.open) || 0),
        approved: Math.max(0, Number(d.approved_minutes) || 0),
        total,
        rows,
        period,
      })
    }
  }
  return out
}

/**
 * Does `iso` show the Working hours line (spec 5.1)? Every working day, by
 * default; a weekend day only when it has minutes, entries or suggestions.
 * @param {string} iso
 * @param {Map<string, any>} index
 */
export function hoursShowsLine(iso, index) {
  if (hoursIsWorkday(iso)) return true
  const d = index && index.get(iso)
  return Boolean(d && (d.total > 0 || d.rows.length > 0))
}

/**
 * The line's state: 'open' (open suggestions or deltas), 'frozen', 'final'
 * (the period approved by the biz owner), 'returned', or '' (nothing to do).
 * @param {any} d an hoursIndex day, or undefined
 */
export function hoursLineState(d) {
  if (!d) return ''
  const ps = String(d.period?.state || '')
  if (ps === 'approved') return 'final'
  if (ps === 'returned') return 'returned'
  if (d.frozen) return 'frozen'
  return d.open > 0 ? 'open' : ''
}

/**
 * What a row is booked against, and how to show it (spec 5.2, R10): a topic
 * is a link to the topic (the day's discussions); the rest are plain rows.
 * `names` maps a target to a known name (a topic subject, '#channel').
 * @param {string} target
 * @param {Record<string, string>} [names]
 * @returns {{ kind: 'topic' | 'channel' | 'dm' | 'meeting' | 'other', id: string, label: string, href: string }}
 */
export function hoursTarget(target, names = {}) {
  const t = String(target || '')
  const known = names && typeof names[t] === 'string' && names[t] ? names[t] : ''
  const m = t.match(/^(t|ch|dm|cal):(.+)$/s)
  if (!m) return { kind: 'other', id: '', label: known, href: '' }
  const id = m[2]
  switch (m[1]) {
    case 't': return { kind: 'topic', id, label: known || id.slice(0, 8), href: `/t/${encodeURIComponent(id)}` }
    case 'ch': return { kind: 'channel', id, label: known || `#${id}`, href: '' }
    case 'dm': return { kind: 'dm', id, label: known || id, href: '' }
    default: return { kind: 'meeting', id, label: known, href: '' }
  }
}

/**
 * The day's discussions first (R10: links to the topics the member took part
 * in), then meetings, channels, DMs and "other"; within a kind, most minutes
 * first. Rejected rows stay (shown struck), last.
 * @param {any[]} rows
 */
export function hoursSortRows(rows) {
  const rank = { topic: 0, meeting: 1, channel: 2, dm: 3, other: 4 }
  return [...(Array.isArray(rows) ? rows : [])].sort((a, b) => {
    const ra = a.state === 'rejected' ? 1 : 0
    const rb = b.state === 'rejected' ? 1 : 0
    if (ra !== rb) return ra - rb
    const ka = rank[hoursTarget(a.target).kind]
    const kb = rank[hoursTarget(b.target).kind]
    if (ka !== kb) return ka - kb
    return (Number(b.minutes) || 0) - (Number(a.minutes) || 0)
  })
}

/** "09:12-10:40" of a row's blocks, in the zone `tz` (the answer's). */
export function hoursBlocksText(blocks, tz) {
  const clock = (iso) => isoDateTimeIn(iso, tz || 'UTC').slice(11, 16)
  return (Array.isArray(blocks) ? blocks : [])
    .map((b) => `${clock(b.start)}-${clock(b.end)}`)
    .filter((s) => s.length > 1)
    .join(', ')
}

/** "YYYY-MM-DD HH:MM" of a freeze instant in the zone `tz`, "" when none. */
export function hoursFreezeText(iso, tz) {
  return iso ? isoDateTimeIn(iso, tz || 'UTC') : ''
}

/**
 * The banner of a period answer (spec 4.2, 5.2): the closed, unfrozen days
 * with open suggestions or deltas, when the period freezes, and a returned
 * period's note.
 * @param {any} body a GET /v1/me/hours answer
 */
export function hoursBanner(body) {
  const days = Array.isArray(body?.days) ? body.days : []
  const open = days.filter((d) => d && d.closed && !d.frozen && Number(d.open) > 0).map((d) => d.date)
  const p = body?.period || {}
  return {
    openDays: open,
    freezesAt: String(p.freezes_at || ''),
    state: String(p.state || 'open'),
    note: String(p.note || ''),
    start: String(p.start || ''),
    end: String(p.end || ''),
  }
}
