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
 * day. The third is the hub's: the workspace's `web` events (rdb 0158, the
 * only audience meant for the internet), read by the page per shown month
 * from the signed-out GET /v1/public/calendar/events
 * (utils/public-calendar-web.mjs, loaded lazily), its rows passed through
 * publicCalendarEvent like these.
 */

import { isSignedOutVisitor } from './shell-bootstrap.mjs'

/** pages/public-calendar.vue */
export const PUBLIC_CALENDAR_PATH = '/public-calendar'

/**
 * Where /calendar sends a settled signed-out visitor (the public calendar),
 * or null: signed in, 'loading', 'unknown' and the mock tenant stay. Read by
 * pages/calendar.vue, a lazy chunk, so the signed-out door adds nothing to
 * the initial download (ci_initial_gzip_kb, c-002 17f99072).
 * @param {unknown} sessionState
 * @param {boolean} [mock]
 * @returns {string | null}
 */
export function signedOutCalendarTarget(sessionState, mock = false) {
  return isSignedOutVisitor(sessionState, mock) ? PUBLIC_CALENDAR_PATH : null
}

/** Where each source's rows come from, in merge order. */
export const PUBLIC_CALENDAR_SOURCES = Object.freeze([
  Object.freeze({ id: 'releases', from: 'build' }),
  Object.freeze({ id: 'features', from: 'build' }),
  Object.freeze({ id: 'web', from: 'hub' }),
])

/**
 * The only kinds an event may have. A feature links its blog post. A release
 * is one day's deploys summed up ("n releases, v<first>..v<last>") and links
 * nowhere: /releases/<ref> reads /v1/release-notes, which the hub refuses to
 * a signed-out visitor (release_notes.go). A web event is one the
 * workspace put on the web calendar: a title, maybe a description and its
 * clock, and no link.
 */
const FEATURE_HREF = /^\/blog\/\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*$/
/** A public release tag: v<X.Y.Z>, or v<X.Y.Z>-c<N> past an odometer wrap (spec 065). */
export const PUBLIC_RELEASE_TAG = /^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c[0-9]{1,4})?$/
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/
const MONTH_RE = /^\d{4}-(0[1-9]|1[0-2])$/
const HHMM_RE = /^([01]\d|2[0-3]):[0-5]\d$/

/**
 * @typedef {{ kind: 'feature', id: string, day: string, at: string, title: string, href: string }} PubFeature
 * @typedef {{ kind: 'release', id: string, day: string, at: string, n: number, first: string, last: string }} PubRelease
 * @typedef {{ kind: 'web', id: string, day: string, at: string, title: string, description: string, allDay: boolean, from: string, to: string }} PubWeb
 * @typedef {PubFeature | PubRelease | PubWeb} PubEvent
 */

/**
 * One row as the page shows it, or null when it is not a public product
 * event: an unknown kind, a feature linking outside /blog, a release with a
 * link or a tag outside PUBLIC_RELEASE_TAG, a web event with a link or no
 * title, no day.
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
  if (r.kind === 'web') {
    const title = String(r.title || '').slice(0, 200)
    if (r.href !== undefined || !title) return null
    const allDay = r.allDay === true
    const from = allDay || !HHMM_RE.test(String(r.from)) ? '' : String(r.from)
    const to = allDay || !HHMM_RE.test(String(r.to)) ? '' : String(r.to)
    const description = String(r.description || '').slice(0, 4000)
    return { kind: 'web', id: `web-${at}-${title}`, day, at, title, description, allDay, from, to }
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
 * releases, its feature posts and its web events.
 * @param {PubEvent[]} events newest first
 * @param {string} month `YYYY-MM`
 */
export function pubCalMonthDays(events, month) {
  /** @type {Map<string, { day: string, releases: PubRelease[], features: PubFeature[], events: PubWeb[] }>} */
  const days = new Map()
  for (const ev of events) {
    if (pubCalMonthOf(ev.day) !== month) continue
    let d = days.get(ev.day)
    if (!d) {
      d = { day: ev.day, releases: [], features: [], events: [] }
      days.set(ev.day, d)
    }
    if (ev.kind === 'release') d.releases.push(ev)
    else if (ev.kind === 'web') d.events.push(ev)
    else d.features.push(ev)
  }
  /* a day's web events by their clock, earliest first */
  for (const d of days.values()) d.events.sort((x, y) => x.at.localeCompare(y.at))
  return [...days.values()]
}
