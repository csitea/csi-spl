/**
 * Spec 118 T005 (sections 6.2, 6.3, T-OV-JS): the WUI's port of the hub's
 * hours.Across (csi-spl-api .../internal/hours/across.go), so today's running
 * timer can be redrawn every minute without a read. One person's hours in
 * several workspaces become, per personal day (the person's zone), "reported"
 * (the sum of what each workspace holds) and "actual" (wall-clock time
 * counted once). Pure: no clock of its own (`now` is given), nothing stored.
 * The shared fixture overlap_fixture.json holds Go and this file to one
 * answer (tests/unit/hours-across.test.mjs).
 *
 * The rules, as across.go numbers them:
 *  1. An entry's spans are placed from the earliest onward until its minutes
 *     are placed, the last one cut short; the rest is unplaced. A rejected
 *     entry counts 0.
 *  2. Placed minutes go to the personal day their span lies in, split at the
 *     person's midnight; unplaced minutes stay on the workspace's date.
 *  3. Reported = placed + unplaced; Open is the part from open suggestions.
 *  4. One workspace's spans overlapping each other count once in actual and
 *     as data_error_minutes.
 *  5. A sweep line (an end before a start at one instant): 2 or more open
 *     workspaces is an overlap interval, 1 or more is the union.
 *  6. Actual = |union| + unplaced (approx when unplaced > 0); Overlap =
 *     Reported - Actual, never negative.
 *  7. A running timer [timer, now) is a provisional span: in actual and the
 *     intervals, never in reported.
 *  8. An unavailable workspace marks its day incomplete and names it.
 */

import { isKnownTimeZone } from './date-iso.mjs'
import { isoDateTimeIn } from './date-iso-zone.mjs'
import { isoSeconds } from './iso-seconds.mjs'

/** @typedef {import('./hours-across').Span} Span */
/** @typedef {import('./hours-across').WorkspaceDay} WorkspaceDay */
/** @typedef {import('./hours-across').PersonalDay} PersonalDay */
/** @typedef {import('./hours-across').Totals} Totals */

export const HOURS_ENTRY_APPROVED = 'approved'
export const HOURS_ENTRY_OPEN = 'open'
export const HOURS_ENTRY_REJECTED = 'rejected'

const MINUTE = 60000
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/

/**
 * An instant as Go's RFC 3339 marshals it: UTC, no fraction on a whole
 * second (every span the hub keeps), milliseconds otherwise.
 */
function rfc3339(ms) {
  const d = new Date(ms)
  return ms % 1000 ? d.toISOString() : isoSeconds(d)
}

function instant(v, what) {
  const ms = Date.parse(String(v ?? ''))
  if (Number.isNaN(ms)) throw new Error(`hours: ${what}: not an instant`)
  return ms
}

/** The civil fields of instant ms in zone, to the minute (date-iso-zone holds the Intl call). */
function civil(ms, zone) {
  const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$/.exec(isoDateTimeIn(ms, zone))
  if (!m) throw new Error(`hours: ${zone}: no civil time`)
  return { year: +m[1], month: +m[2], day: +m[3], hour: +m[4], minute: +m[5] }
}

/** The personal day (YYYY-MM-DD in zone) that instant ms lies in. */
export function hoursDayIn(ms, zone) {
  return isoDateTimeIn(ms, zone).slice(0, 10)
}

/** The UTC instant of the midnight that starts the day after ms's day, in zone. */
function nextMidnight(ms, zone) {
  const p = civil(ms, zone)
  const wall = Date.UTC(p.year, p.month - 1, p.day + 1)
  let guess = wall
  for (let i = 0; i < 3; i++) {
    const g = civil(guess, zone)
    const offset = Date.UTC(g.year, g.month - 1, g.day, g.hour, g.minute) - guess
    const next = wall - offset
    if (next === guess) break
    guess = next
  }
  return guess
}

/** Cut span s ({start, end} ms) at each midnight of zone. */
function splitAtMidnight(s, zone) {
  const parts = []
  let start = s.start
  while (start < s.end) {
    const next = nextMidnight(start, zone)
    if (next >= s.end || next <= start) {
      parts.push({ start, end: s.end, provisional: s.provisional })
      break
    }
    parts.push({ start, end: next, provisional: s.provisional })
    start = next
  }
  return parts
}

const byStart = (a, b) => a.start - b.start
const minutesOf = (s) => Math.floor((s.end - s.start) / MINUTE)

/** 5.3's placement: the spans from the earliest onward, the last cut short. */
function place(spans, minutes) {
  let left = minutes * MINUTE
  const placed = []
  for (const s of [...spans].sort(byStart)) {
    if (left <= 0) break
    const end = s.end - s.start > left ? s.start + left : s.end
    left -= end - s.start
    placed.push({ start: s.start, end, provisional: false })
  }
  return { placed, unplaced: Math.floor(left / MINUTE) }
}

function checkEntry(wd, e) {
  if (![HOURS_ENTRY_APPROVED, HOURS_ENTRY_OPEN, HOURS_ENTRY_REJECTED].includes(e.state)) {
    throw new Error(`hours: ${wd.workspace} ${wd.day}: entry state "${e.state}"`)
  }
  if (!(Number(e.minutes) >= 0)) throw new Error(`hours: ${wd.workspace} ${wd.day}: negative minutes`)
  const spans = (e.spans || []).map((s) => ({ start: instant(s.start, 'span start'), end: instant(s.end, 'span end') }))
  if (spans.some((s) => s.end <= s.start)) throw new Error(`hours: ${wd.workspace} ${wd.day}: span does not end after its start`)
  return spans
}

function newDay() {
  return { spans: new Map(), shares: new Map(), reported: 0, open: 0, unplaced: 0, unavailable: [] }
}

function shareOf(d, ws) {
  if (!d.shares.has(ws)) d.shares.set(ws, { minutes: 0, open: 0, spans: [] })
  return d.shares.get(ws)
}

function addMinutes(d, ws, minutes, open) {
  const sh = shareOf(d, ws)
  sh.minutes += minutes
  d.reported += minutes
  if (open) {
    sh.open += minutes
    d.open += minutes
  }
}

function addSpan(d, ws, s, open) {
  if (!d.spans.has(ws)) d.spans.set(ws, [])
  d.spans.get(ws).push(s)
  shareOf(d, ws).spans.push(s)
  if (!s.provisional) addMinutes(d, ws, minutesOf(s), open)
}

/** One workspace's spans merged; dup = minutes its entered spans overlap each other. */
function union(spans) {
  const merged = []
  let enteredEnd = -Infinity
  let dup = 0
  for (const s of [...spans].sort(byStart)) {
    if (!s.provisional) {
      if (s.start < enteredEnd) dup += minutesOf({ start: s.start, end: Math.min(s.end, enteredEnd) })
      if (s.end > enteredEnd) enteredEnd = s.end
    }
    const last = merged[merged.length - 1]
    if (last && s.start <= last.end) {
      if (s.end > last.end) last.end = s.end
      continue
    }
    merged.push({ start: s.start, end: s.end })
  }
  return { merged, dup }
}

/** The union's minutes and the stretches with 2 or more workspaces open. */
function sweep(events) {
  events.sort((a, b) => a.at - b.at || a.delta - b.delta)
  const open = new Map()
  let total = 0
  const out = []
  events.forEach((ev, i) => {
    const from = i > 0 ? events[i - 1].at : ev.at
    if (i > 0 && open.size > 0 && ev.at > from) {
      total += ev.at - from
      if (open.size >= 2) {
        const ws = [...open.keys()].sort()
        const last = out[out.length - 1]
        if (last && last.end === from && last.workspaces.join('\0') === ws.join('\0')) last.end = ev.at
        else out.push({ start: from, end: ev.at, workspaces: ws })
      }
    }
    const n = (open.get(ev.ws) || 0) + ev.delta
    if (n === 0) open.delete(ev.ws)
    else open.set(ev.ws, n)
  })
  return { minutes: Math.floor(total / MINUTE), intervals: out }
}

const spanOut = (s) => (s.provisional
  ? { start: rfc3339(s.start), end: rfc3339(s.end), provisional: true }
  : { start: rfc3339(s.start), end: rfc3339(s.end) })

function result(day, d) {
  const events = []
  let dataError = 0
  for (const [ws, spans] of d.spans) {
    const { merged, dup } = union(spans)
    dataError += dup
    for (const s of merged) events.push({ at: s.start, ws, delta: 1 }, { at: s.end, ws, delta: -1 })
  }
  const { minutes, intervals } = sweep(events)
  const unavailable = [...d.unavailable].sort()
  const actual = minutes + d.unplaced
  /** @type {Record<string, any>} */
  const workspaces = {}
  for (const [ws, sh] of d.shares) {
    const out = { minutes: sh.minutes, open: sh.open, spans: [...sh.spans].sort(byStart).map(spanOut) }
    if (sh.state) out.state = sh.state
    if (sh.standard_day) out.standard_day = sh.standard_day
    workspaces[ws] = out
  }
  return {
    day,
    reported: d.reported,
    open: d.open,
    actual,
    overlap: Math.max(0, d.reported - actual),
    unplaced: d.unplaced,
    data_error_minutes: dataError,
    approx: d.unplaced > 0,
    incomplete: unavailable.length > 0,
    unavailable,
    overlap_intervals: intervals.map((iv) => ({ start: rfc3339(iv.start), end: rfc3339(iv.end), workspaces: iv.workspaces })),
    workspaces,
  }
}

/**
 * The personal days of `days` in `zone` (IANA), sorted by day. A day appears
 * when a workspace day names it or a span reaches into it.
 * @param {WorkspaceDay[]} days
 * @param {string} zone
 * @param {Date | string | number} now
 * @returns {PersonalDay[]}
 */
export function hoursAcross(days, zone, now) {
  if (!zone) throw new Error('hours: no time zone')
  if (!isKnownTimeZone(zone)) throw new Error(`hours: unknown time zone "${zone}"`)
  const nowMs = typeof now === 'number' ? now : now instanceof Date ? now.getTime() : instant(now, 'now')
  /** @type {Map<string, ReturnType<typeof newDay>>} */
  const acc = new Map()
  const get = (day) => {
    if (!acc.has(day)) acc.set(day, newDay())
    return acc.get(day)
  }
  for (const wd of days || []) {
    if (!DAY_RE.test(String(wd.day || ''))) throw new Error(`hours: day "${wd.day}": not YYYY-MM-DD`)
    const home = get(wd.day)
    const share = shareOf(home, wd.workspace)
    share.state = wd.state || ''
    share.standard_day = wd.standard_day || 0
    if (wd.unavailable) {
      home.unavailable.push(wd.workspace)
      continue
    }
    for (const e of wd.entries || []) {
      const spans = checkEntry(wd, e)
      if (e.state === HOURS_ENTRY_REJECTED) continue
      const { placed, unplaced } = place(spans, Number(e.minutes))
      for (const s of placed) {
        for (const part of splitAtMidnight(s, zone)) addSpan(get(hoursDayIn(part.start, zone)), wd.workspace, part, e.state === HOURS_ENTRY_OPEN)
      }
      if (unplaced > 0) {
        home.unplaced += unplaced
        addMinutes(home, wd.workspace, unplaced, e.state === HOURS_ENTRY_OPEN)
      }
    }
    if (wd.timer) {
      const start = instant(wd.timer, 'timer')
      if (nowMs > start) {
        for (const part of splitAtMidnight({ start, end: nowMs, provisional: true }, zone)) {
          addSpan(get(hoursDayIn(part.start, zone)), wd.workspace, part, false)
        }
      }
    }
  }
  return [...acc.keys()].sort().map((day) => result(day, acc.get(day)))
}

/**
 * A window's totals: the sum of its days, never a second union.
 * @param {PersonalDay[]} days
 * @returns {Totals}
 */
export function hoursSum(days) {
  const t = { reported: 0, open: 0, actual: 0, overlap: 0, unplaced: 0, data_error_minutes: 0 }
  for (const d of days || []) for (const k of Object.keys(t)) t[k] += Number(d[k]) || 0
  return t
}

/**
 * Today's running timers redrawn on one personal day of the realm read
 * (6.3 open timer): the day's per-workspace spans and unplaced minutes go
 * back through `hoursAcross` with each timer's [start, now) as a provisional
 * span. Reported and open stay what the hub answered (a timer is not
 * entered yet); actual, overlap and the intervals move with now. The
 * day's spans already lie inside it, so nothing spills to another day.
 * @param {PersonalDay} day
 * @param {Record<string, string>} timers workspace -> RFC 3339 start
 * @param {string} zone
 * @param {Date | string | number} now
 * @returns {PersonalDay}
 */
export function hoursWithTimers(day, timers, zone, now) {
  const running = Object.entries(timers || {}).filter(([, start]) => start)
  if (!day || !running.length) return day
  const input = []
  const names = new Set([...Object.keys(day.workspaces || {}), ...running.map(([ws]) => ws)])
  for (const ws of names) {
    const sh = day.workspaces?.[ws]
    const spans = (sh?.spans || []).filter((s) => !s.provisional).map(({ start, end }) => ({ start, end }))
    const placed = spans.reduce((n, s) => n + Math.floor((Date.parse(s.end) - Date.parse(s.start)) / MINUTE), 0)
    const entries = []
    if (spans.length) entries.push({ target: 'placed', minutes: placed, state: HOURS_ENTRY_APPROVED, spans })
    const unplaced = Math.max(0, (sh?.minutes || 0) - placed)
    if (unplaced) entries.push({ target: 'unplaced', minutes: unplaced, state: HOURS_ENTRY_APPROVED })
    input.push({ workspace: ws, day: day.day, state: sh?.state, standard_day: sh?.standard_day, entries, timer: timers?.[ws] || undefined })
  }
  for (const ws of day.unavailable || []) input.push({ workspace: ws, day: day.day, unavailable: true })
  const got = hoursAcross(input, zone, now).find((d) => d.day === day.day)
  if (!got) return day
  for (const [ws, sh] of Object.entries(got.workspaces)) {
    sh.open = day.workspaces?.[ws]?.open || 0
  }
  return { ...got, open: day.open, reported: day.reported, overlap: Math.max(0, day.reported - got.actual) }
}

/**
 * The limit row in effect on `day`: the latest whose valid_from is not after it.
 * @template {{ valid_from: string }} L
 * @param {L[]} limits
 * @param {string} day YYYY-MM-DD
 * @returns {L | null}
 */
export function hoursLimitInEffect(limits, day) {
  let best = null
  for (const l of limits || []) if (l.valid_from <= day && (!best || l.valid_from > best.valid_from)) best = l
  return best
}

/**
 * The D3 warning level of `actual` minutes against a limit (8.1): amber at
 * 90 %, red past 100 %; 'none' without a limit.
 * @param {number} actual
 * @param {number | null | undefined} limit
 * @returns {'none' | 'amber' | 'red'}
 */
export function hoursLimitLevel(actual, limit) {
  if (!limit || limit <= 0) return 'none'
  if (actual > limit) return 'red'
  if (actual * 10 >= limit * 9) return 'amber'
  return 'none'
}
