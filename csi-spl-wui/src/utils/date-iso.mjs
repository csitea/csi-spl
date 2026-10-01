/**
 * Absolute dates are YYYY-MM-DD, and a date with a time is YYYY-MM-DD HH:MM
 * in 24-hour local wall time: the viewer's own (browser) time zone, never UTC.
 * CLE-77908 (owner, "off by 3hours"): every message / topic clock the WUI
 * prints goes through these helpers, so no view drifts back to UTC. The same instant prints the same way in every
 * UI locale. Relative ages ("7s", "2h 3m") are not dates and stay as they are.
 */

const pad = (n) => String(n).padStart(2, "0")

function asDate(value) {
  if (value instanceof Date) return value
  const d = new Date(value)
  return Number.isNaN(d.getTime()) ? null : d
}

/** Local calendar day, or "" when value is not a time. */
export function isoDate(value) {
  const d = asDate(value)
  if (!d) return ""
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

/** Local HH:MM, or "" when value is not a time. */
export function isoClock(value) {
  const d = asDate(value)
  if (!d) return ""
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`
}

/** Local YYYY-MM-DD HH:MM, or "" when value is not a time. */
export function isoDateTime(value) {
  const d = asDate(value)
  if (!d) return ""
  return `${isoDate(d)} ${isoClock(d)}`
}

/** Local YYYY-MM-DD HH:MM:SS, or "" when value is not a time. */
export function isoDateTimeSec(value) {
  const d = asDate(value)
  if (!d) return ""
  return `${isoDateTime(d)}:${pad(d.getSeconds())}`
}

/** A typed day. "" when it is not a real YYYY-MM-DD calendar day. */
export function parseIsoDate(value) {
  const m = String(value || "").trim().match(/^(\d{4})-(\d{2})-(\d{2})$/)
  if (!m) return ""
  const y = Number(m[1])
  const mo = Number(m[2])
  const day = Number(m[3])
  if (mo < 1 || mo > 12 || day < 1 || day > 31) return ""
  const dt = new Date(Date.UTC(y, mo - 1, day))
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== day) return ""
  return `${m[1]}-${m[2]}-${m[3]}`
}
