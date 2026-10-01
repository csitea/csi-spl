/**
 * CLE-77908 (owner, topic 07b84fd7, requirements 2 + 5): a time written as
 * TEXT inside a message body is shown in the reader's zone when, and only when,
 * it says which instant it is: an ISO 8601 date-time with a zone (`Z` or
 * `+hh:mm` / `-hhmm`), e.g. `2026-10-01T18:46:26Z`. Agents on a UTC box and a
 * reader in Helsinki then see the same hour.
 *
 * A time with no zone (`18:46`, `2026-10-01 18:46`) is left exactly as
 * written: nobody can know which zone its writer meant, so it is never
 * guessed or converted. Code spans and code blocks never reach this (they are
 * their own parts), so a pasted log keeps its literal stamps.
 */
import { isoDateTime, isoDateTimeSec } from './date-iso.mjs'

/* date, T or one space, HH:MM[:SS[.frac]], then the zone. Not inside a longer
   token: no word character or ':' right before or after. */
const ISO_ZONED_RE = /(?<![\w:.-])(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(:\d{2}(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})(?![\w:+-])/g

/**
 * Split `text` into runs: { text } stays as written, { text, iso } is an
 * instant (`iso` = the text as written, `text` = the reader's wall time, with
 * seconds when the original had them).
 * @param {string} text
 * @returns {{ text: string, iso?: string }[]}
 */
export function bodyTimeRuns(text) {
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
  return out
}

/** True when `text` holds at least one zoned ISO time to localise. */
export function hasBodyTime(text) {
  ISO_ZONED_RE.lastIndex = 0
  const hit = ISO_ZONED_RE.test(String(text ?? ''))
  ISO_ZONED_RE.lastIndex = 0
  return hit
}
