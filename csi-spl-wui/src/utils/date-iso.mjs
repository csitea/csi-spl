/**
 * Absolute dates are YYYY-MM-DD, and a date with a time is YYYY-MM-DD HH:MM
 * in 24-hour wall time of the VIEWER's time zone, never UTC. The same instant
 * prints the same way in every UI locale. Relative ages ("7s", "2h 3m") are
 * not dates and stay as they are.
 *
 * CLE-77908 (owner, "off by 3hours"; topic 07b84fd7): every message / topic
 * clock the WUI prints goes through these helpers. The zone is the person's
 * own pick for this workspace (Settings -> Appearance, hub `time_zone`, per
 * tenant), else the browser's zone. This is the ONE file that may call
 * Intl.DateTimeFormat (date-iso.test.mjs bans it everywhere else).
 */

const pad = (n) => String(n).padStart(2, "0")

function asDate(value) {
  if (value instanceof Date) return value
  const d = new Date(value)
  return Number.isNaN(d.getTime()) ? null : d
}

/* The picked zone, read through a getter so a Vue app can hand in a reactive
   source: a computed that prints a time then re-renders when the zone changes.
   "" = the browser's zone. Node tests use process.env.TZ for that. */
let zoneSource = () => ""
const fmtCache = new Map()

/** The IANA zone the browser runs in ("" when Intl cannot say). */
export function browserTimeZone() {
  try {
    return new Intl.DateTimeFormat().resolvedOptions().timeZone || ""
  } catch {
    return ""
  }
}

/** True when `zone` is an IANA zone this browser knows. */
export function isKnownTimeZone(zone) {
  return !!zone && typeof zone === "string" && formatterFor(zone) !== null
}

/** Every IANA zone this browser knows, sorted ([] when Intl cannot list). */
export function knownTimeZones() {
  try {
    const all = typeof Intl.supportedValuesOf === "function" ? Intl.supportedValuesOf("timeZone") : []
    return [...new Set(["UTC", ...all])].sort()
  } catch {
    return []
  }
}

function formatterFor(zone) {
  if (fmtCache.has(zone)) return fmtCache.get(zone)
  let f = null
  try {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: zone, hourCycle: "h23",
      year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
    })
  } catch {
    f = null
  }
  fmtCache.set(zone, f)
  return f
}

/**
 * Where the zone comes from. `source` is a function answering an IANA zone or
 * "" (the browser's). An unknown zone falls back to the browser's.
 * @param {() => string} source
 */
export function setTimeZoneSource(source) {
  zoneSource = typeof source === "function" ? source : () => ""
}

/** The zone the helpers print in now: the picked one, else "" (browser). */
export function viewerTimeZone() {
  const z = String(zoneSource() || "")
  return z && isKnownTimeZone(z) ? z : ""
}

/** Wall-clock fields of `d` in the viewer's zone. */
function fields(d) {
  const zone = viewerTimeZone()
  const f = zone ? formatterFor(zone) : null
  if (!f) {
    return { y: d.getFullYear(), mo: d.getMonth() + 1, da: d.getDate(), h: d.getHours(), mi: d.getMinutes(), s: d.getSeconds() }
  }
  const p = {}
  for (const x of f.formatToParts(d)) p[x.type] = Number(x.value)
  return { y: p.year, mo: p.month, da: p.day, h: p.hour % 24, mi: p.minute, s: p.second }
}

/** Wall-clock fields {y, mo, da, h, mi, s} of value in the viewer's zone, or null. */
export function isoFields(value) {
  const d = asDate(value)
  return d ? fields(d) : null
}

const abbrCache = new Map()
function abbrFormatter(locale, zone) {
  const k = `${locale}|${zone}`
  if (abbrCache.has(k)) return abbrCache.get(k)
  let f = null
  try {
    f = new Intl.DateTimeFormat(locale, zone ? { timeZone: zone, timeZoneName: "short" } : { timeZoneName: "short" })
  } catch {
    f = null
  }
  abbrCache.set(k, f)
  return f
}

/**
 * The viewer's zone as a short name at that instant ("EEST", "EDT", "UTC"),
 * else the offset Intl prints ("GMT+5:30"); "" when Intl cannot say. en-GB
 * names the European zones, en-US the American ones: the first that is a
 * name and not a GMT offset wins.
 */
export function zoneAbbr(value) {
  const d = asDate(value)
  if (!d) return ""
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

/** Calendar day in the viewer's zone, or "" when value is not a time. */
export function isoDate(value) {
  const d = asDate(value)
  if (!d) return ""
  const f = fields(d)
  return `${f.y}-${pad(f.mo)}-${pad(f.da)}`
}

/** HH:MM in the viewer's zone, or "" when value is not a time. */
export function isoClock(value) {
  const d = asDate(value)
  if (!d) return ""
  const f = fields(d)
  return `${pad(f.h)}:${pad(f.mi)}`
}

/** YYYY-MM-DD HH:MM in the viewer's zone, or "" when value is not a time. */
export function isoDateTime(value) {
  const d = asDate(value)
  if (!d) return ""
  const f = fields(d)
  return `${f.y}-${pad(f.mo)}-${pad(f.da)} ${pad(f.h)}:${pad(f.mi)}`
}

/** YYYY-MM-DD HH:MM:SS in the viewer's zone, or "" when value is not a time. */
export function isoDateTimeSec(value) {
  const d = asDate(value)
  if (!d) return ""
  const f = fields(d)
  return `${f.y}-${pad(f.mo)}-${pad(f.da)} ${pad(f.h)}:${pad(f.mi)}:${pad(f.s)}`
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
