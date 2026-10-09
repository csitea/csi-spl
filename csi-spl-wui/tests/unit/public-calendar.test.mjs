// HUM-10 (t1 ef57739c, a8e3d31d): the public calendar's data and its door.
//   - the build-time rows: release tags (spec 065) and live `feature` blog
//     posts (spec 111); a draft, an untagged post and a bad tag are left out
//   - publicCalendarEvent keeps only those two kinds with their own links:
//     a tenant calendar event (spec 089 6.1.1, audience `public`) is dropped.
//     Control: the same tenant row reshaped as a release passes, so the drop
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
  'v2.0.0\tnot-a-date',
].join('\n')
const rel = releaseRows(TAGS)
ok('release rows: the two v<X.Y.Z>[-cN] tags with a date', rel.length === 2, JSON.stringify(rel))
ok('release row: day in UTC, link /releases/<tag>', rel[0].day === '2026-10-09' && rel[0].at === '2026-10-09T14:38:38Z' && rel[0].href === '/releases/v4.3.8-c2', JSON.stringify(rel[0]))

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
ok('mock releases: one per mock version (70)', mock.length === 70 && mock.every((r) => r.kind === 'release'), String(mock.length))

const TENANT = { id: '00000000-0000-4000-8000-000000000999', source: 'event', title: 'Tenant board meeting', kind: 'other', audience: 'public', starts_at: '2026-10-09T09:00:00Z', ends_at: '2026-10-09T10:00:00Z' }
ok('a tenant calendar event is not a public event', publicCalendarEvent(TENANT) === null)
ok('control: the same title as a release row passes', publicCalendarEvent({ kind: 'release', title: TENANT.title, day: '2026-10-09', href: '/releases/v1.0.0' }) !== null)
ok('a release linking elsewhere is dropped', publicCalendarEvent({ kind: 'release', title: 'x', day: '2026-10-09', href: 'https://evil.example/x' }) === null)
ok('a feature linking a tenant topic is dropped', publicCalendarEvent({ kind: 'feature', title: 'x', day: '2026-10-09', href: '/t/abc' }) === null)

const merged = mergePublicCalendar(rel, feat, [TENANT], rel)
ok('merge: tenant row dropped, duplicates once, newest first', merged.length === 3 && merged[0].href === '/releases/v4.3.8-c2' && !merged.some((e) => e.title === TENANT.title), JSON.stringify(merged.map((e) => e.href)))

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
