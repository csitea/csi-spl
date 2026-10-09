// HUM-10 (t1 ef57739c, a8e3d31d): the public calendar's data and its door.
//   - the build-time rows: release tags (spec 065), ONE entry per day with no
//     link, only v<X.Y.Z>[-cN]; live `feature` blog posts (spec 111); a draft,
//     an untagged post and a bad tag are left out
//   - publicCalendarEvent keeps only those two kinds with their own links:
//     a tenant calendar event (spec 089 6.1.1, audience `public`) is dropped.
//     Control: the same tenant title as a feature row passes, so the drop
//     is the filter, not a malformed fixture.
//   - the shown month and the day groups
//   - signedOutPublicTarget: a settled signed-out /calendar goes to
//     /public-calendar; signed in, mock, loading and other paths stay
//
// Run: node tests/unit/public-calendar.test.mjs
import { featureRows, mockReleaseRows, publicCalendarData, releaseRows } from '../../src/node/pubcal/public-calendar-data.mjs'
import {
  PUBLIC_CALENDAR_SOURCES, mergePublicCalendar, pubCalAddMonths, pubCalMonthDays, pubCalShownMonth, publicCalendarEvent,
} from '../../src/utils/public-calendar.mjs'
import { PUBLIC_CALENDAR_PATH, signedOutPublicTarget } from '../../src/utils/signed-out-redirect.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

const TAGS = [
  'v4.3.8-c2\t2026-10-09T17:38:38+03:00',
  'v1.1.3\t2026-09-27T21:31:09Z',
  'v1.1\t2026-09-27T21:31:09Z',
  'release-1\t2026-09-27T21:31:09Z',
  'v1.1.4-rc1\t2026-09-27T21:31:09Z',
  'v2.0.0\tnot-a-date',
].join('\n')
const rel = releaseRows(TAGS)
ok('release rows: the two v<X.Y.Z>[-cN] tags with a date, one per day', rel.length === 2, JSON.stringify(rel))
ok('release row: UTC day, n, first/last, NO href', rel[0].day === '2026-10-09' && rel[0].at === '2026-10-09T14:38:38Z' && rel[0].n === 1 && rel[0].first === 'v4.3.8-c2' && !('href' in rel[0]), JSON.stringify(rel[0]))

/* c-002 cd67354c: a day of 50 deploys is ONE entry, first..last by time,
   no other suffix, no link */
const DAY50 = []
for (let i = 0; i < 50; i++) DAY50.push(`v5.${Math.floor(i / 10)}.${i % 10}-c2\t2026-10-05T${String(Math.floor(i / 3)).padStart(2, '0')}:${String((i % 3) * 10).padStart(2, '0')}:00Z`)
DAY50.push('v5.9.9-rc1\t2026-10-05T23:59:00Z', 'v5.9.8-x\t2026-10-05T23:58:00Z', 'v0.0.1\t2026-10-05T00:00:00Z')
const d50 = releaseRows(DAY50.join('\n'))
ok('50 tags in a day: 1 release entry', d50.length === 1 && d50[0].n === 51, JSON.stringify(d50))
ok('50 tags in a day: first/last by tag time', d50[0].first === 'v0.0.1' && d50[0].last === 'v5.4.9-c2', JSON.stringify(d50[0]))
ok('no suffix but -cN gets in', !JSON.stringify(d50).includes('-rc1') && !JSON.stringify(d50).includes('-x'))
const file50 = publicCalendarData({ tags: DAY50.join('\n'), blogIndex: null })
ok('the file: every release entry has no href', file50.events.length === 1 && file50.events.every((e) => e.kind === 'release' && !('href' in e)), JSON.stringify(file50.events))
ok('a release row carrying a link is dropped', publicCalendarEvent({ ...d50[0], href: '/releases/v5.4.9-c2' }) === null)
ok('a release row with a suffixed tag is dropped', publicCalendarEvent({ ...d50[0], last: 'v5.9.9-rc1' }) === null)

const BLOG = {
  locales: {
    en: [
      { id: '2026-10-09-feature-calendar', title: 'Calendar', published: '2026-10-09T14:38:00Z', date: '2026-10-09', tags: ['feature', 'calendar'] },
      { id: '2026-10-08-feature-draft', title: 'Draft', date: '2026-10-08', tags: ['feature'], draft: true },
      { id: '2026-10-07-hello', title: 'Hello', date: '2026-10-07', tags: ['fleet'] },
    ],
    fi: [{ id: '2026-10-09-feature-calendar', title: 'Kalenteri', date: '2026-10-09', tags: ['feature'] }],
  },
}
const feat = featureRows(BLOG)
ok('feature rows: only the live en post tagged feature', feat.length === 1 && feat[0].href === '/blog/2026-10-09-feature-calendar' && feat[0].day === '2026-10-09', JSON.stringify(feat))
ok('feature rows: no blog copy = none', featureRows(null).length === 0)

const mock = mockReleaseRows()
ok('mock releases: one entry per day, 70 versions in all', mock.length > 0 && mock.length < 70 && mock.reduce((a, r) => a + r.n, 0) === 70 && new Set(mock.map((r) => r.day)).size === mock.length, String(mock.length))

const TENANT = { id: '00000000-0000-4000-8000-000000000999', source: 'event', title: 'Tenant board meeting', kind: 'other', audience: 'public', starts_at: '2026-10-09T09:00:00Z', ends_at: '2026-10-09T10:00:00Z' }
ok('a tenant calendar event is not a public event', publicCalendarEvent(TENANT) === null)
ok('control: the same title as a feature row passes', publicCalendarEvent({ kind: 'feature', title: TENANT.title, day: '2026-10-09', href: '/blog/2026-10-09-board' }) !== null)
ok('a feature linking elsewhere is dropped', publicCalendarEvent({ kind: 'feature', title: 'x', day: '2026-10-09', href: 'https://evil.example/x' }) === null)
ok('a feature linking a tenant topic is dropped', publicCalendarEvent({ kind: 'feature', title: 'x', day: '2026-10-09', href: '/t/abc' }) === null)

const merged = mergePublicCalendar(rel, feat, [TENANT], rel)
ok('merge: tenant row dropped, duplicates once, newest first', merged.length === 3 && merged[0].id === 'releases-2026-10-09' && !merged.some((e) => e.title === TENANT.title), JSON.stringify(merged.map((e) => e.id)))

const data = publicCalendarData({ tags: TAGS, blogIndex: BLOG })
ok('the file: v1, releases and the feature post', data.v === 1 && data.events.length === 3, JSON.stringify(data))
ok('sources: releases then features', PUBLIC_CALENDAR_SOURCES.map((s) => s.id).join() === 'releases,features')

ok('shown month: asked one wins', pubCalShownMonth(merged, '2026-01', '2026-10-09') === '2026-01')
ok('shown month: this month when it has events', pubCalShownMonth(merged, '', '2026-10-20') === '2026-10')
ok('shown month: else the newest with events', pubCalShownMonth(merged, 'junk', '2026-12-01') === '2026-10')
ok('add months over a year', pubCalAddMonths('2026-12', 1) === '2027-01' && pubCalAddMonths('2026-01', -1) === '2025-12')
const days = pubCalMonthDays(merged, '2026-10')
ok('month days: one day, a release and a feature', days.length === 1 && days[0].releases.length === 1 && days[0].features.length === 1, JSON.stringify(days))

ok('signed out on /calendar -> the public calendar', signedOutPublicTarget('/calendar?d=2026-10-01', 'out') === PUBLIC_CALENDAR_PATH)
ok('signed out on /fi/calendar -> the public calendar', signedOutPublicTarget('/fi/calendar', 'out') === PUBLIC_CALENDAR_PATH)
ok('signed in stays', signedOutPublicTarget('/calendar', 'in') === null)
ok('loading and unknown stay', signedOutPublicTarget('/calendar', 'loading') === null && signedOutPublicTarget('/calendar', 'unknown') === null)
ok('the mock tenant stays', signedOutPublicTarget('/calendar', 'out', true) === null)
ok('other paths stay', signedOutPublicTarget('/calendars', 'out') === null && signedOutPublicTarget('/', 'out') === null)

console.log(failed ? `\n${failed} FAILED` : '\nall passed')
process.exit(failed ? 1 : 0)
