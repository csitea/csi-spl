/**
 * spec 097 T014: YYYY-MM-DD HH:MM of an instant in a GIVEN IANA zone (an
 * event's own `time_zone`), for the calendar's event dialog only. date-iso.mjs
 * prints in the viewer's zone and sits in the first-screen chunk; this
 * zone-explicit twin is imported by calendar code alone, so it stays in the
 * calendar's lazy chunk (spec 097 FR-013). The second and last file that may
 * call Intl.DateTimeFormat (tests/unit/date-iso.test.mjs). zoneAbbr (t1
 * 179ef3f9) names the reader's zone for the short body times, also lazy
 * (body-times-short.mjs).
 */
import { browserTimeZone, isoDateTime, viewerTimeZone } from "./date-iso.mjs"

const pad = (n) => String(n).padStart(2, "0")
const fmtCache = new Map()

function formatterFor(zone) {
  if (!fmtCache.has(zone)) {
    let f = null
    try {
      f = new Intl.DateTimeFormat("en-US", {
        timeZone: zone, hourCycle: "h23",
        year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
      })
    } catch {
      f = null
    }
    fmtCache.set(zone, f)
  }
  return fmtCache.get(zone)
}

/**
 * YYYY-MM-DD HH:MM of `value` in `zone`; the viewer's zone (date-iso) when
 * `zone` is "" or unknown; "" when `value` is not a time.
 */
export function isoDateTimeIn(value, zone) {
  const d = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(d.getTime())) return ""
  const f = zone ? formatterFor(zone) : null
  if (!f) return isoDateTime(d)
  const p = {}
  for (const x of f.formatToParts(d)) p[x.type] = Number(x.value)
  return `${p.year}-${pad(p.month)}-${pad(p.day)} ${pad(p.hour % 24)}:${pad(p.minute)}`
}

const abbrCache = new Map()
function abbrFormatter(locale, zone) {
  const k = `${locale}|${zone}`
  if (!abbrCache.has(k)) {
    let f = null
    try {
      f = new Intl.DateTimeFormat(locale, { timeZone: zone || undefined, timeZoneName: "short" })
    } catch {
      f = null
    }
    abbrCache.set(k, f)
  }
  return abbrCache.get(k)
}

/**
 * The viewer's zone as a short name at that instant ("EEST", "EDT", "UTC"),
 * else the offset Intl prints ("GMT+5:30"); "" when Intl cannot say. en-GB
 * names the European zones, en-US the American ones: the first that is a
 * name and not a GMT offset wins.
 */
export function zoneAbbr(value) {
  const d = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(d.getTime())) return ""
  const zone = viewerTimeZone() || browserTimeZone()
  let fallback = ""
  for (const locale of ["en-GB", "en-US"]) {
    const f = abbrFormatter(locale, zone)
    const name = f ? (f.formatToParts(d).find((x) => x.type === "timeZoneName") || {}).value || "" : ""
    if (name && !/^GMT[+-]/.test(name)) return name
    fallback = fallback || name
  }
  return fallback
}
