// The public calendar's data (HUM-10 t1 ef57739c / a8e3d31d), written at
// build time to src/public/pub-cal/events.json (git-ignored) by nuxt.config's
// publicCalendarModule, so /public-calendar reads one static file and never
// a tenant API.
//
// Sources, both non-tenant (src/utils/public-calendar.mjs
// PUBLIC_CALENDAR_SOURCES):
//   releases  every v<X.Y.Z>[-cN] git tag (spec 065; -cN is the version
//             odometer's cycle N after the 9.9.9 wrap, e.g. v4.4.2-c2 is the
//             deploy whose footer shows 4.4.2), summed to ONE entry per UTC
//             day ("n releases, first..last", in tag time order) with no
//             link: release notes need a signed-in session. Any other suffix
//             is left out. A shallow clone has no tags; the mock bundle uses
//             the mock tenant's release list (utils/release-notes-api.mjs).
//   features  the live (`draft: false`) blog posts tagged `feature`
//             (spec 111), from the copy sync-blog.mjs wrote before
//             `nuxt generate` (src/public/blog-md/index.json).
// Every row passes publicCalendarEvent: a row of another kind or link is
// dropped, so nothing else can be written here.
//
// Usage:
//   node src/node/pubcal/public-calendar-data.mjs         # write the file
//   node src/node/pubcal/public-calendar-data.mjs --mock  # with the mock releases
import { spawnSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { isoSeconds } from '../../utils/iso-seconds.mjs'
import { PUBLIC_RELEASE_TAG, mergePublicCalendar } from '../../utils/public-calendar.mjs'
import { mockReleaseNotes } from '../../utils/release-notes-api.mjs'

export const WUI = join(dirname(fileURLToPath(import.meta.url)), '../../..')
export const PUBCAL_FILE = join(WUI, 'src/public/pub-cal/events.json')
const BLOG_INDEX = join(WUI, 'src/public/blog-md/index.json')

/**
 * One release entry per UTC day from `git for-each-ref` lines
 * (`<tag>\t<iso date>`): n, and the first and last tag by time.
 * @param {string} text
 */
export function releaseRows(text) {
  /** @type {Map<string, { tag: string, at: string }[]>} */
  const byDay = new Map()
  for (const line of String(text || '').split('\n')) {
    const [tag, iso] = line.split('\t')
    const t = Date.parse(iso || '')
    if (!PUBLIC_RELEASE_TAG.test(tag || '') || Number.isNaN(t)) continue
    const at = isoSeconds(new Date(t))
    const day = at.slice(0, 10)
    if (!byDay.has(day)) byDay.set(day, [])
    byDay.get(day)?.push({ tag, at })
  }
  const out = []
  for (const [day, tags] of byDay) {
    tags.sort((a, b) => a.at.localeCompare(b.at) || a.tag.localeCompare(b.tag))
    const last = tags[tags.length - 1]
    out.push({ kind: 'release', day, at: last.at, n: tags.length, first: tags[0].tag, last: last.tag })
  }
  return out
}

/** The release tags of the repo at `dir` ('' when git or the tags are missing). */
export function readReleaseTags(dir = WUI) {
  const r = spawnSync('git', ['-C', dir, 'for-each-ref', 'refs/tags/v*', '--format=%(refname:short)%09%(creatordate:iso-strict)'], { encoding: 'utf8' })
  return r.status === 0 ? r.stdout : ''
}

/** The mock tenant's releases, as release rows (one per day). */
export function mockReleaseRows() {
  const all = []
  let before = ''
  for (let i = 0; i < 10; i++) {
    const page = mockReleaseNotes(`/v1/release-notes?limit=30${before ? `&before=${before}` : ''}`, '')
    all.push(...page.versions)
    if (!page.next_before) break
    before = page.next_before
  }
  return releaseRows(all.map((v) => `${v.version}\t${v.notes?.[0]?.committed_at || ''}`).join('\n'))
}

/**
 * Feature rows from the blog copy's index: the en posts tagged `feature`.
 * @param {{ locales?: Record<string, Array<Record<string, unknown>>> } | null} index
 */
export function featureRows(index) {
  const out = []
  for (const e of index?.locales?.en || []) {
    if (e.draft === true || !Array.isArray(e.tags) || !e.tags.includes('feature')) continue
    const at = String(e.published || e.date || '')
    out.push({ kind: 'feature', id: String(e.id), day: at.slice(0, 10), at, title: String(e.title || e.id), href: `/blog/${e.id}` })
  }
  return out
}

/** The blog copy's index, or null when sync-blog.mjs has not run. */
export function readBlogIndex(file = BLOG_INDEX) {
  try { return JSON.parse(readFileSync(file, 'utf8')) } catch { return null }
}

/**
 * The file's content: { v, events } with every source merged.
 * @param {{ tags: string, mock?: boolean, blogIndex: unknown }} input
 */
export function publicCalendarData({ tags, mock = false, blogIndex }) {
  const releases = mock ? mockReleaseRows() : releaseRows(tags)
  const features = featureRows(/** @type {any} */ (blogIndex))
  return { v: 1, events: mergePublicCalendar(releases, features) }
}

/** Write src/public/pub-cal/events.json; returns the event count. */
export function writePublicCalendar({ mock = false, file = PUBCAL_FILE } = {}) {
  const data = publicCalendarData({ tags: mock ? '' : readReleaseTags(), mock, blogIndex: readBlogIndex() })
  mkdirSync(dirname(file), { recursive: true })
  writeFileSync(file, `${JSON.stringify(data)}\n`)
  return data.events.length
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const n = writePublicCalendar({ mock: process.argv.includes('--mock') })
  console.log(`wrote ${n} public calendar events to ${PUBCAL_FILE}`)
}
