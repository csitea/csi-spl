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
 * no `at` (a doc, an issue description) a short form stays as written. The
 * code is body-times-short.mjs, lazy (it rides the app-link-label chunk); until it
 * has loaded a short form reads as written. Each display choice is one small
 * function there (shortClock, dayLabel,
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
import { isoDateTime, isoDateTimeSec } from './date-iso.mjs'

/* date, T or one space, HH:MM[:SS[.frac]], then the zone. Not inside a longer
   token: no word character or ':' right before or after. */
const ISO_ZONED_RE = /(?<![\w:.-])(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(:\d{2}(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})(?![\w:+-])/g

/** provide/inject key: MessageBody hands a getter of its message timestamp to MessageRuns. */
export const BODY_TIME_AT = 'spl-body-time-at'

/**
 * Split `text` into runs: { text } stays as written, { text, iso, dt? } is an
 * instant (`iso` = the text as written, the hover; `text` = the reader's wall
 * time, with seconds when the original had them; `dt` = the full UTC instant
 * of a short form, for <time datetime>).
 * @param {string} text
 * @param {string|number|Date} [at] the message timestamp: the day of a short form
 * @param {(runs: { text: string, iso?: string }[], at: unknown) => { text: string, iso?: string, dt?: string }[]} [short]
 *   withShortTimes from the lazy body-times-short.mjs; absent = short forms as written
 * @returns {{ text: string, iso?: string, dt?: string }[]}
 */
export function bodyTimeRuns(text, at, short) {
  const s = String(text ?? '')
  const out = []
  let last = 0
  for (const m of s.matchAll(ISO_ZONED_RE)) {
    const zone = m[4].length === 5 ? m[4].slice(0, 3) + ':' + m[4].slice(3) : m[4]
    const d = new Date(`${m[1]}T${m[2]}${m[3] || ''}${zone}`)
    if (Number.isNaN(d.getTime())) continue
    if (m.index > last) out.push({ text: s.slice(last, m.index) })
    out.push({ text: m[3] ? isoDateTimeSec(d) : isoDateTime(d), iso: m[0] })
    last = m.index + m[0].length
  }
  if (last < s.length || out.length === 0) out.push({ text: s.slice(last) })
  return short ? short(out, at) : out
}

/**
 * True when `text` may hold a zoned time (ISO or short) to localise: a cheap
 * superset (HH:MM[:SS] or HH:Mx, then Z or an offset); bodyTimeRuns and
 * body-times-short.mjs decide exactly.
 */
export function hasBodyTime(text) {
  return /\d:[0-5][\dx](:\d\d)?(Z|[+-]\d\d:?\d\d)/.test(String(text ?? ''))
}
