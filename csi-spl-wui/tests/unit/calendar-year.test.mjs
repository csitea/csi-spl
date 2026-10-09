// spec 089 T007: the year strip's date arithmetic (36 mini-months, Monday
// weeks, UTC days) and the mock workspace's answers in the wire format of
// spec 6.1 (the shapes the hub's T004 handlers answer).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  calAddDays, calDayMs, calIsoDay, calMarks, calMarksQuery, calMonth, calStripMonths,
  calStripYears, calWeekDays, calWeekStart, calWeekday,
} from '../../src/utils/calendar-year.mjs'
import { mockCalendarEvents, mockCalendarItems, mockCalendarMarks } from '../../src/utils/calendar-mock.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('days', () => {
  it('a UTC day is YYYY-MM-DD; anything else is not a day', () => {
    assert.equal(calIsoDay(Date.UTC(2026, 9, 5, 23, 59)), '2026-10-05')
    assert.equal(calIsoDay('nope'), '')
    assert.equal(calDayMs('2026-10-05'), Date.UTC(2026, 9, 5))
    for (const bad of ['', '2026-02-30', '2026-13-01', '05.10.2026', '2026-10-5']) assert.ok(Number.isNaN(calDayMs(bad)), bad)
    assert.equal(calAddDays('2026-12-31', 1), '2027-01-01')
    assert.equal(calAddDays('2024-03-01', -1), '2024-02-29')
    assert.equal(calAddDays('x', 1), '')
  })
  it('weeks start on Monday', () => {
    assert.equal(calWeekStart('2026-10-05'), '2026-10-05')
    assert.equal(calWeekStart('2026-10-11'), '2026-10-05')
    assert.equal(calWeekStart('2027-01-01'), '2026-12-28')
    assert.deepEqual(calWeekDays('2026-10-08'), ['2026-10-05', '2026-10-06', '2026-10-07', '2026-10-08', '2026-10-09', '2026-10-10', '2026-10-11'])
    assert.equal(calWeekday('2026-10-05'), 1)
    assert.equal(calWeekday('2026-10-11'), 7)
    assert.equal(calWeekday('x'), 0)
    assert.deepEqual(calWeekDays(''), [])
  })
})

describe('the strip', () => {
  it('holds the previous, the current and the next year: 36 months', () => {
    assert.deepEqual(calStripYears('2026-10-05'), [2025, 2026, 2027])
    const months = calStripMonths(calStripYears('2026-10-05'))
    assert.equal(months.length, 36)
    assert.equal(months[0].key, '2025-01')
    assert.equal(months.at(-1).key, '2027-12')
    assert.equal(months.reduce((n, m) => n + m.days.length, 0), 365 + 365 + 365)
  })
  it('a month knows its blank cells before day 1 on a Monday-first row', () => {
    assert.equal(calMonth(2026, 9).lead, 3, 'October 2026 starts on a Thursday')
    assert.equal(calMonth(2026, 5).lead, 0, 'June 2026 starts on a Monday')
    assert.equal(calMonth(2026, 1).days.length, 28)
    assert.equal(calMonth(2028, 1).days.length, 29)
    assert.deepEqual(calMonth(2026, 9).days[0], { iso: '2026-10-01', d: 1 })
  })
  it('asks the hub for the strip years (6.1.2)', () => {
    assert.equal(calMarksQuery([2025, 2026, 2027]), 'start_year=2025&end_year=2027')
  })
  it('reads marks into dots and tints, tolerant of junk', () => {
    const m = calMarks({ days: [{ day: '2026-10-05', count: 2, kinds: ['deadline', 'release'] }, { day: 'bad', count: 1 }, { day: '2026-10-06', count: 0 }], official_days: [{ day: '2026-12-25', title: 'X' }, { day: 'nope' }] })
    assert.deepEqual([...m.days.keys()], ['2026-10-05'])
    assert.deepEqual(m.days.get('2026-10-05'), { count: 2, kinds: ['deadline', 'release'] })
    assert.deepEqual([...m.official], [['2026-12-25', 'X']])
    for (const junk of [null, undefined, 'x', { days: 'x', official_days: 3 }]) {
      const e = calMarks(junk)
      assert.equal(e.days.size + e.official.size, 0)
    }
  })
})

/* spec 6.1.1: one shape for every item, whatever its source */
const FIELDS = ['id', 'source', 'title', 'description', 'kind', 'starts_at', 'ends_at', 'all_day', 'audience', 'mentions',
  'creator_type', 'creator_id', 'remind_at', 'topic_id', 'release_version', 'issue_key', 'created_at', 'updated_at',
  /* 097 4.1, the fields T014 edits */
  'time_zone', 'location', 'color', 'reminders']

describe('the mock answers 6.1', () => {
  const today = '2026-10-05'
  it('every item has exactly the 6.1.1 fields, strings never null, lists arrays', () => {
    for (const x of mockCalendarItems(today)) {
      assert.deepEqual(Object.keys(x).sort(), [...FIELDS].sort(), x.id)
      for (const k of FIELDS) assert.notEqual(x[k], null, `${x.id}.${k}`)
      assert.ok(Array.isArray(x.mentions))
      assert.ok(['event', 'issue', 'official_day'].includes(x.source))
      assert.ok(['workspace', 'internal', 'private'].includes(x.audience))
      assert.ok(Date.parse(x.ends_at) >= Date.parse(x.starts_at), x.id)
      if (x.source === 'issue') assert.equal(x.issue_key, x.id)
      if (x.source === 'official_day') assert.equal(x.all_day, true)
    }
  })
  it('events: the items overlapping [start, end), by starts_at then id', () => {
    const body = mockCalendarEvents('2026-10-05T00:00:00Z', '2026-10-12T00:00:00Z', today)
    assert.equal(body.start, '2026-10-05T00:00:00Z')
    assert.equal(body.end, '2026-10-12T00:00:00Z')
    assert.deepEqual(body.events.map((x) => x.kind), ['release', 'maintenance', 'deadline'])
    const sorted = [...body.events].sort((a, b) => a.starts_at.localeCompare(b.starts_at) || a.id.localeCompare(b.id))
    assert.deepEqual(body.events, sorted)
    assert.deepEqual(mockCalendarEvents('2026-10-12T00:00:00Z', '2026-10-19T00:00:00Z', today).events, [])
  })
  it('marks: per UTC day count + sorted kinds, oldest first; official days as tints', () => {
    const body = mockCalendarMarks(2025, 2027, today)
    assert.equal(body.start_year, 2025)
    assert.equal(body.end_year, 2027)
    assert.deepEqual(body.days[0], { day: '2026-10-05', count: 1, kinds: ['release'] })
    assert.deepEqual(body.days[1], { day: '2026-10-07', count: 2, kinds: ['deadline', 'maintenance'] })
    assert.deepEqual(body.official_days, [{ day: '2026-12-25', title: 'Official day' }])
    assert.deepEqual(mockCalendarMarks(2030, 2030, today).days, [])
  })
})

describe('wiring', () => {
  it('the page keeps the main view in its own chunk and the strip in this page only', () => {
    const page = read('src/pages/calendar.vue')
    assert.match(page, /defineAsyncComponent\(\(\) => import\('~\/components\/CalendarMainView\.vue'\)\)/)
    assert.match(page, /<CalendarYearStrip /)
    assert.doesNotMatch(read('src/components/ChannelSidebar.vue'), /calendar-(year|mock)\.mjs/)
    assert.doesNotMatch(read('src/layouts/default.vue'), /Calendar/)
  })
  it('the strip reads GET /v1/calendar/marks and the main view GET /v1/calendar/events', () => {
    assert.match(read('src/components/CalendarYearStrip.vue'), /\/v1\/calendar\/marks\?/)
    assert.match(read('src/components/CalendarMainView.vue'), /\/v1\/calendar\/events\?/)
  })
  it('every catalogue names the twelve months and seven weekdays', () => {
    for (const code of ['en', 'bg', 'el', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const cal = JSON.parse(read(`i18n/locales/${code}.json`)).calendar
      assert.equal(Object.keys(cal.months).length, 12, code)
      assert.equal(Object.keys(cal.weekdays).length, 7, code)
      assert.equal(Object.keys(cal.weekdays_narrow).length, 7, code)
      assert.equal(typeof JSON.parse(read(`i18n/locales/${code}.json`)).sidebar.calendar, 'string', code)
    }
  })
})
