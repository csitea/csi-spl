// spec 089 T007: the Calendar section's year strip - 36 mini-months (the
// previous, the current and the next year) with event dots and official-day
// tints from GET /v1/calendar/marks (spec 6.1.2). Pure date arithmetic, no
// library (spec 3: "Pure custom Vue component using standard date
// calculations"). Days are UTC calendar days, as the hub counts marks per UTC
// day (6.1.2), written 'YYYY-MM-DD'. Weeks start on Monday (spec 2 layout).
// Loaded only by the /calendar page, never by the shell.

const DAY_MS = 86400000
const ISO_DAY_RE = /^(\d{4})-(\d{2})-(\d{2})$/

/**
 * The UTC calendar day of `date` as 'YYYY-MM-DD'.
 * @param {Date | number | string} date
 * @returns {string}
 */
export function calIsoDay(date) {
  const d = date instanceof Date ? date : new Date(date)
  return Number.isNaN(d.getTime()) ? '' : d.toISOString().slice(0, 10)
}

/**
 * Milliseconds of a 'YYYY-MM-DD' day at 00:00 UTC; NaN for anything else.
 * @param {string} iso
 * @returns {number}
 */
export function calDayMs(iso) {
  const m = ISO_DAY_RE.exec(String(iso || ''))
  if (!m) return NaN
  const ms = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
  return calIsoDay(ms) === iso ? ms : NaN
}

/**
 * The day `n` days after `iso` ('' when `iso` is not a day).
 * @param {string} iso
 * @param {number} n
 * @returns {string}
 */
export function calAddDays(iso, n) {
  const ms = calDayMs(iso)
  return Number.isNaN(ms) ? '' : calIsoDay(ms + Math.trunc(Number(n) || 0) * DAY_MS)
}

/**
 * The Monday that starts the week holding `iso` ('' when `iso` is not a day).
 * @param {string} iso
 * @returns {string}
 */
export function calWeekStart(iso) {
  const ms = calDayMs(iso)
  if (Number.isNaN(ms)) return ''
  const back = (new Date(ms).getUTCDay() + 6) % 7
  return calIsoDay(ms - back * DAY_MS)
}

/**
 * The day of the week of `iso`, 1 = Monday .. 7 = Sunday (0 when not a day).
 * @param {string} iso
 * @returns {number}
 */
export function calWeekday(iso) {
  const ms = calDayMs(iso)
  return Number.isNaN(ms) ? 0 : ((new Date(ms).getUTCDay() + 6) % 7) + 1
}

/**
 * The seven days, Monday first, of the week holding `iso`.
 * @param {string} iso
 * @returns {string[]}
 */
export function calWeekDays(iso) {
  const start = calWeekStart(iso)
  if (!start) return []
  return Array.from({ length: 7 }, (_, i) => calAddDays(start, i))
}

/**
 * The strip's three years around `todayIso`: previous, current, next.
 * @param {string} todayIso
 * @returns {number[]}
 */
export function calStripYears(todayIso) {
  const y = Number(String(todayIso || '').slice(0, 4)) || new Date().getUTCFullYear()
  return [y - 1, y, y + 1]
}

/**
 * One mini-month: its key ('YYYY-MM'), the blank cells before day 1 on a
 * Monday-first row (`lead`, 0..6) and its days.
 * @param {number} year
 * @param {number} month0 0 = January
 * @returns {{ key: string, year: number, month0: number, lead: number, days: { iso: string, d: number }[] }}
 */
export function calMonth(year, month0) {
  const first = Date.UTC(year, month0, 1)
  const count = new Date(Date.UTC(year, month0 + 1, 0)).getUTCDate()
  const days = Array.from({ length: count }, (_, i) => ({ iso: calIsoDay(first + i * DAY_MS), d: i + 1 }))
  return {
    key: `${year}-${String(month0 + 1).padStart(2, '0')}`,
    year,
    month0,
    lead: (new Date(first).getUTCDay() + 6) % 7,
    days,
  }
}

/**
 * Every month of `years`, oldest first: 36 for the strip's three years.
 * @param {number[]} years
 * @returns {ReturnType<typeof calMonth>[]}
 */
export function calStripMonths(years) {
  const out = []
  for (const y of years) for (let m = 0; m < 12; m++) out.push(calMonth(y, m))
  return out
}

/**
 * The marks query of 6.1.2 for the strip's years.
 * @param {number[]} years
 * @returns {string}
 */
export function calMarksQuery(years) {
  return `start_year=${Math.min(...years)}&end_year=${Math.max(...years)}`
}

/**
 * GET /v1/calendar/marks (6.1.2) as two lookups by day: `days` (count and
 * kinds, for the dots) and `official` (the title, for the tints). Tolerant of
 * a missing or malformed body: an unknown day simply has no mark.
 * @param {unknown} body
 * @returns {{ days: Map<string, { count: number, kinds: string[] }>, official: Map<string, string> }}
 */
export function calMarks(body) {
  const days = new Map()
  const official = new Map()
  const b = body && typeof body === 'object' ? /** @type {Record<string, unknown>} */ (body) : {}
  for (const row of Array.isArray(b.days) ? b.days : []) {
    const day = String((row && row.day) || '')
    const count = Number(row && row.count) || 0
    if (Number.isNaN(calDayMs(day)) || count <= 0) continue
    days.set(day, { count, kinds: Array.isArray(row.kinds) ? row.kinds.map(String) : [] })
  }
  for (const row of Array.isArray(b.official_days) ? b.official_days : []) {
    const day = String((row && row.day) || '')
    if (!Number.isNaN(calDayMs(day))) official.set(day, String((row && row.title) || ''))
  }
  return { days, official }
}
