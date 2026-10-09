/**
 * CLE-77908 (owner, topic 07b84fd7, requirements 2 + 5): a time written as
 * TEXT inside a message body is shown in the reader's zone when, and only when,
 * it says which instant it is: an ISO 8601 date-time with a zone (`Z` or
 * `+hh:mm` / `-hhmm`), e.g. `2026-10-01T18:46:26Z`. Agents on a UTC box and a
 * reader in Helsinki then see the same hour.
 *
 * Owner HUM-10, t1 179ef3f9: agents also write SHORT UTC times: `07:05:30Z`,
 * `10:45Z`, `10:4xZ` (a minute digit is x: "about"), ranges `10:15-10:17Z`,
 * `09:53Z..10:23Z`. They carry no day, so the day is the message's own: of
 * the UTC days around the message timestamp `at`, the one that puts the time
 * nearest to it (a post at 00:10Z saying `23:50Z` means the day before). With
 * no `at` (a doc, an issue description) a short form stays as written. Each
 * display choice is one small function below (shortClock, dayLabel,
 * zoneLabel, utcLabel, approxLabel); the owner's answers (msg 4da3a44d):
 *   - 1c: the reader's clock and zone, then the UTC as written:
 *     `10:05:30 EEST (07:05:30 UTC)`; a range `13:15-13:17 EEST (10:15-10:17 UTC)`;
 *   - 2: on another calendar day for the reader than the post's own day (the
 *     post's timestamp on the reader's clock), the full date comes first:
 *     `2026-10-10 02:30 EEST (23:30 UTC)`;
 *   - 3b: an `x` minute is "about" the middle of its ten minutes (x = 5):
 *     `10:4xZ` reads `about 13:45 EEST (about 10:45 UTC)`; an "about" already
 *     written right before it is not repeated;
 *   - 4b: no marker on the converted time; the hover keeps it as written.
 *
 * A time with no zone (`18:46`, `10:45`, `2026-10-01 18:46`) is left exactly
 * as written: nobody can know which zone its writer meant, so it is never
 * guessed or converted. Code spans and code blocks never reach this (they are
 * their own parts), so a pasted log keeps its literal stamps.
 */
import { isoDateTime, isoDateTimeSec, isoFields, zoneAbbr } from './date-iso.mjs'

/* date, T or one space, HH:MM[:SS[.frac]], then the zone. Not inside a longer
   token: no word character or ':' right before or after. */
const ISO_ZONED_RE = /(?<![\w:.-])(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(:\d{2}(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})(?![\w:+-])/g

/* HH:MM[:SS] or HH:Mx, then Z; a range: the first end's Z is optional. */
const T = '(\\d{2}):([0-5][\\dx])(?::([0-5]\\d))?'
const SHORT_RE = new RegExp(`(?<![\\w:.+\\-–])${T}Z(?![\\w:+\\-–]|\\.\\.)`, 'g')
const RANGE_RE = new RegExp(`(?<![\\w:.+\\-–])${T}Z?(\\s?(?:-|–|\\.\\.)\\s?)${T}Z(?![\\w:+\\-–])`, 'g')

const pad = (n) => String(n).padStart(2, '0')
const DAY_MS = 86400000
const WEEKDAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

/* Choice 3b: an `x` minute digit is the middle of its ten minutes. */
const APPROX_DIGIT = '5'

/* One end as written -> { ms, approx, sec } or null (hour > 23, x with seconds). */
function shortEnd(h, m, s) {
  const approx = m.endsWith('x')
  if (Number(h) > 23 || (approx && s)) return null
  const ms = ((Number(h) * 60 + Number(approx ? m[0] + APPROX_DIGIT : m)) * 60 + Number(s || 0)) * 1000
  return { ms, approx, sec: s !== undefined }
}

/* The instant: of the UTC days around `at`, the one nearest to `at`. */
function nearestInstant(msOfDay, at) {
  const day0 = Math.floor(at / DAY_MS) * DAY_MS
  let best = day0 + msOfDay
  for (const d of [day0 - DAY_MS, day0 + DAY_MS]) {
    if (Math.abs(d + msOfDay - at) < Math.abs(best - at)) best = d + msOfDay
  }
  return best
}

/* The clock of wall fields f: HH:MM, or HH:MM:SS when the writer gave seconds. */
function shortClock(f, end) {
  return end.sec ? `${pad(f.h)}:${pad(f.mi)}:${pad(f.s)}` : `${pad(f.h)}:${pad(f.mi)}`
}

/* Choice 2: the full date when the reader's day is not the post's day. */
function dayLabel(f, day) {
  return day && (f.y !== day.y || f.mo !== day.mo || f.da !== day.da) ? `${f.y}-${pad(f.mo)}-${pad(f.da)} ` : ''
}

/* Choice 1c: the zone named after the clock. */
function zoneLabel(ms) {
  const z = zoneAbbr(ms)
  return z ? ` ${z}` : ''
}

/* Choice 1c: the UTC as written, after the reader's clock. */
function utcLabel(utc) {
  return ` (${utc} UTC)`
}

/* Choice 3b: an x form reads "about"; not twice when the writer said it. */
function approxLabel(approx, before) {
  return approx && !/\babout\s*$/i.test(before) ? 'about ' : ''
}

/* UTC wall fields of ms, for the original in brackets */
function utcFields(ms) {
  const d = new Date(ms)
  return { h: d.getUTCHours(), mi: d.getUTCMinutes(), s: d.getUTCSeconds() }
}

function endText(ms, end, day) {
  const f = isoFields(ms)
  return f ? dayLabel(f, day) + shortClock(f, end) : ''
}

function isoMatch(m) {
  const zone = m[4].length === 5 ? m[4].slice(0, 3) + ':' + m[4].slice(3) : m[4]
  const d = new Date(`${m[1]}T${m[2]}${m[3] || ''}${zone}`)
  if (Number.isNaN(d.getTime())) return null
  return { text: m[3] ? isoDateTimeSec(d) : isoDateTime(d), iso: m[0] }
}

function shortMatch(m, at, before) {
  const end = shortEnd(m[1], m[2], m[3])
  if (!end) return null
  const ms = nearestInstant(end.ms, at)
  const about = approxLabel(end.approx, before)
  const text = about + endText(ms, end, isoFields(at)) + zoneLabel(ms) + utcLabel((end.approx ? 'about ' : '') + shortClock(utcFields(ms), end))
  return { text, iso: m[0], dt: new Date(ms).toISOString() }
}

function rangeMatch(m, at, before) {
  const a = shortEnd(m[1], m[2], m[3])
  const b = shortEnd(m[5], m[6], m[7])
  if (!a || !b) return null
  const ms0 = nearestInstant(a.ms, at)
  const ms1 = ms0 - a.ms + b.ms + (b.ms < a.ms ? DAY_MS : 0)
  const about = approxLabel(a.approx || b.approx, before)
  /* the end names its date only when it is not the start's day */
  const local = about + endText(ms0, a, isoFields(at)) + m[4] + endText(ms1, b, isoFields(ms0))
  const utc = (a.approx || b.approx ? 'about ' : '') + shortClock(utcFields(ms0), a) + m[4] + shortClock(utcFields(ms1), b)
  return { text: local + zoneLabel(ms1) + utcLabel(utc), iso: m[0], dt: new Date(ms0).toISOString() }
}

/* Every match, earliest first; ISO beats a range beats a single short time. */
function matches(s, at) {
  const found = []
  const scan = (re, rank, conv) => {
    for (const m of s.matchAll(re)) found.push({ i: m.index, n: m[0].length, rank, conv: () => conv(m, at, s.slice(0, m.index)) })
  }
  scan(ISO_ZONED_RE, 0, isoMatch)
  if (Number.isFinite(at)) {
    scan(RANGE_RE, 1, rangeMatch)
    scan(SHORT_RE, 2, shortMatch)
  }
  return found.sort((x, y) => x.i - y.i || x.rank - y.rank)
}

function atMs(at) {
  if (at === undefined || at === null || at === '') return NaN
  return typeof at === 'number' ? at : new Date(at).getTime()
}

/** provide/inject key: MessageBody hands its message timestamp to MessageRuns. */
export const BODY_TIME_AT = 'spl-body-time-at'

/**
 * Split `text` into runs: { text } stays as written, { text, iso, dt? } is an
 * instant (`iso` = the text as written, the hover; `text` = the reader's wall
 * time; `dt` = the full UTC instant of a short form, for <time datetime>).
 * @param {string} text
 * @param {string|number|Date} [at] the message timestamp: the day of a short form
 * @returns {{ text: string, iso?: string, dt?: string }[]}
 */
export function bodyTimeRuns(text, at) {
  const s = String(text ?? '')
  const out = []
  let last = 0
  for (const x of matches(s, atMs(at instanceof Date ? at.getTime() : at))) {
    if (x.i < last) continue
    const run = x.conv()
    if (!run) continue
    if (x.i > last) out.push({ text: s.slice(last, x.i) })
    out.push(run)
    last = x.i + x.n
  }
  if (last < s.length || out.length === 0) out.push({ text: s.slice(last) })
  return out
}

/** True when `text` holds at least one zoned time (ISO or short) to localise. */
export function hasBodyTime(text) {
  const s = String(text ?? '')
  return [ISO_ZONED_RE, RANGE_RE, SHORT_RE].some((re) => {
    re.lastIndex = 0
    const hit = re.test(s)
    re.lastIndex = 0
    return hit
  })
}
