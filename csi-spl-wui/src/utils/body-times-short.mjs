/**
 * The short UTC times of a message body (owner HUM-10, t1 179ef3f9): `07:05:30Z`,
 * `10:45Z`, `10:4xZ`, `10:15-10:17Z`, `09:53Z..10:23Z`, on the reader's clock.
 * The rules are in body-times.mjs; this is their code, a lazy chunk
 * (re-exported by app-link-label.mjs, which MessageRuns loads lazily): MessageRuns is on the first paint and the initial JS
 * is at its ceiling (027 perf-budgets.json), so a short time reads as written
 * for a moment, then converted.
 */
import { isoDateTimeSec } from './date-iso.mjs'
import { zoneAbbr } from './date-iso-zone.mjs'

/* Wall-clock fields of ms in the reader's zone, read from date-iso's print
   (date-iso.mjs is the first screen: nothing new goes in there) */
function isoFields(ms) {
  const m = isoDateTimeSec(ms).match(/^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/)
  return m ? { y: +m[1], mo: +m[2], da: +m[3], h: +m[4], mi: +m[5], s: +m[6] } : null
}

/* HH:MM[:SS] or HH:Mx, then Z; a range: the first end's Z is optional. */
const T = '(\\d{2}):([0-5][\\dx])(?::([0-5]\\d))?'
const SHORT_RE = new RegExp(`(?<![\\w:.+\\-–])${T}Z(?![\\w:+\\-–]|\\.\\.)`, 'g')
const RANGE_RE = new RegExp(`(?<![\\w:.+\\-–])${T}Z?(\\s?(?:-|–|\\.\\.)\\s?)${T}Z(?![\\w:+\\-–])`, 'g')

const pad = (n) => String(n).padStart(2, '0')
const DAY_MS = 86400000

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

/**
 * Split a text run with no ISO time into runs: { text } as written,
 * { text, iso, dt } a short time on the reader's clock (`iso` = as written).
 * A range beats the single times inside it.
 * @param {string} s
 * @param {number} at the message timestamp, epoch ms
 * @returns {{ text: string, iso?: string, dt?: string }[]}
 */
export function shortTimeRuns(s, at) {
  const found = []
  for (const [re, rank, conv] of [[RANGE_RE, 0, rangeMatch], [SHORT_RE, 1, shortMatch]]) {
    for (const m of s.matchAll(re)) found.push({ i: m.index, n: m[0].length, rank, m, conv })
  }
  found.sort((x, y) => x.i - y.i || x.rank - y.rank)
  const out = []
  let last = 0
  for (const x of found) {
    if (x.i < last) continue
    const run = x.conv(x.m, at, s.slice(0, x.i))
    if (!run) continue
    if (x.i > last) out.push({ text: s.slice(last, x.i) })
    out.push(run)
    last = x.i + x.n
  }
  if (last < s.length || out.length === 0) out.push({ text: s.slice(last) })
  return out
}

/**
 * The runs of bodyTimeRuns with each short time in its text runs converted,
 * on the day of `at` (the message timestamp); as they are when `at` is not a time.
 * @param {{ text: string, iso?: string }[]} runs
 * @param {unknown} at
 */
export function withShortTimes(runs, at) {
  const ms = at === undefined || at === null || at === '' ? NaN : new Date(at).getTime()
  if (!Number.isFinite(ms)) return runs
  return runs.flatMap((r) => (r.iso ? [r] : shortTimeRuns(r.text, ms)))
}
