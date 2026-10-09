/**
 * The public calendar (HUM-10 t1 ef57739c / a8e3d31d): what a signed-out
 * visitor of /public-calendar sees. Product events only, never a tenant
 * calendar entry: the tenant audience `public` means "everyone in the
 * workspace", not the internet (rdb 0125), so no tenant calendar API is read.
 *
 * The events come from PUBLIC_CALENDAR_SOURCES. Today both are written at
 * `nuxt generate` time into /pub-cal/events.json
 * (src/node/pubcal/public-calendar-data.mjs): the release tags (spec 065) and
 * the live `feature` blog posts (spec 111), releases summed to one entry per
 * day. A later source (the hub's `web`
 * audience, lane pub-cal-web-audience) is one more entry in that list, its
 * rows passed through publicCalendarEvent like these.
 */

/** Where each source's rows come from, in merge order. */
export const PUBLIC_CALENDAR_SOURCES = Object.freeze([
  Object.freeze({ id: 'releases', from: 'build' }),
  Object.freeze({ id: 'features', from: 'build' }),
])

/**
 * The only kinds an event may have. A feature links its blog post. A release
 * is one day's deploys summed up ("n releases, v<first>..v<last>") and links
 * nowhere: /releases/<ref> reads /v1/release-notes, which the hub refuses to
 * a signed-out visitor (release_notes.go).
 */
const FEATURE_HREF = /^\/blog\/\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*$/
/** A public release tag: v<X.Y.Z>, or v<X.Y.Z>-c<N> past an odometer wrap (spec 065). */
export const PUBLIC_RELEASE_TAG = /^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c[0-9]{1,4})?$/
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/
const MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])$/

/**
 * @typedef {{ kind: 'feature', id: string, day: string, at: string, title: string, href: string }} PubFeature
 * @typedef {{ kind: 'release', id: string, day: string, at: string, n: number, first: string, last: string }} PubRelease
 * @typedef {PubFeature | PubRelease} PubEvent
 */

/**
 * One row as the page shows it, or null when it is not a public product
 * event: an unknown kind, a feature linking outside /blog, a release with a
 * link or a tag outside PUBLIC_RELEASE_TAG, no day.
 * @param {unknown} row
 * @returns {PubEvent | null}
 */
export function publicCalendarEvent(row) {
  if (!row || typeof row !== 'object') return null
  const r = /** @type {Record<string, unknown>} */ (row)
  const day = String(r.day || '')
  if (!DAY_RE.test(day)) return null
  const at = String(r.at || '')
  if (r.kind === 'feature') {
    const href = String(r.href || '')
    const title = String(r.title || '').slice(0, 200)
    if (!FEATURE_HREF.test(href) || !title) return null
    return { kind: 'feature', id: String(r.id || href), day, at, title, href }
  }
  if (r.kind === 'release') {
    const n = Number(r.n)
    const first = String(r.first || '')
    const last = String(r.last || '')
    if (r.href !== undefined || !Number.isInteger(n) || n < 1) return null
    if (!PUBLIC_RELEASE_TAG.test(first) || !PUBLIC_RELEASE_TAG.test(last)) return null
    return { kind: 'release', id: `releases-${day}`, day, at, n, first, last }
  }
  return null
}

/**
 * Every source's rows as one list, newest first, each event once.
 * @param {...unknown[]} sources
 */
export function mergePublicCalendar(...sources) {
  const seen = new Set()
  const out = []
  for (const rows of sources) {
    for (const row of Array.isArray(rows) ? rows : []) {
      const ev = publicCalendarEvent(row)
      if (!ev || seen.has(ev.id)) continue
      seen.add(ev.id)
      out.push(ev)
    }
  }
  return out.sort((a, b) => (b.day + b.at).localeCompare(a.day + a.at))
}

/**
 * `YYYY-MM` of a day.
 * @param {string} day
 */
export const pubCalMonthOf = (day) => String(day || '').slice(0, 7)

/**
 * The month `step` months after `month` (`YYYY-MM`).
 * @param {string} month
 * @param {number} step
 */
export function pubCalAddMonths(month, step) {
  const [y, m] = month.split('-').map(Number)
  const d = new Date(Date.UTC(y, m - 1 + step, 1))
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`
}

/**
 * The month to show: the asked one when valid, else this month when it has
 * an event, else the newest month that has one, else this month.
 * @param {{ day: string }[]} events newest first
 * @param {string} asked `?m=` from the address
 * @param {string} today `YYYY-MM-DD`
 */
export function pubCalShownMonth(events, asked, today) {
  if (MONTH_RE.test(String(asked || ''))) return String(asked)
  const now = pubCalMonthOf(today)
  if (!events.length || events.some((e) => pubCalMonthOf(e.day) === now)) return now
  return pubCalMonthOf(events[0].day)
}

/**
 * The days of one month that have events, newest first, each with its
 * releases and its feature posts.
 * @param {PubEvent[]} events newest first
 * @param {string} month `YYYY-MM`
 */
export function pubCalMonthDays(events, month) {
  /** @type {Map<string, { day: string, releases: PubRelease[], features: PubFeature[] }>} */
  const days = new Map()
  for (const ev of events) {
    if (pubCalMonthOf(ev.day) !== month) continue
    let d = days.get(ev.day)
    if (!d) {
      d = { day: ev.day, releases: [], features: [] }
      days.set(ev.day, d)
    }
    if (ev.kind === 'release') d.releases.push(ev)
    else d.features.push(ev)
  }
  return [...days.values()]
}
