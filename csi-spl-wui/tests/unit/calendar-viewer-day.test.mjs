// The calendar's "today" and fetch windows are the VIEWER's days (c-262's
// class, the rest of it): the grid draws a timed event on the viewer's day
// (calEventDay), so the default week, the phone's fetch and the public
// calendar's month must use that day too, not the UTC one.
//   - calToday: the viewer's day; pinned Sunday 21:30Z is local Monday at
//     Europe/Helsinki (+03), still Sunday at UTC and in New York
//   - pages/calendar.vue opens the week of calToday(), not calIsoDay(now)
//   - CalendarPhone fetches calLoadWindow(range), not [from 00:00Z, to 00:00Z):
//     local Monday 00:30 at +03 is Sunday 21:30Z, outside the UTC day
//   - pages/public-calendar.vue: today = calToday(), not the UTC slice
// Control: the UTC forms the sites used before give the other day at the
// pinned clock, so a site back on them is red.
//
// Run: node --test tests/unit/calendar-viewer-day.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { calIsoDay, calLoadWindow, calToday } from '../../src/utils/calendar-year.mjs'
import { calPhoneRange } from '../../src/utils/calendar-phone-nav.mjs'
import { setTimeZoneSource } from '../../src/utils/date-iso.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
/* Sunday 2026-10-11 21:30Z = Monday 00:30 at Europe/Helsinki */
const PIN = Date.UTC(2026, 9, 11, 21, 30)

function pinned(zone, fn) {
  const real = Date.now
  Date.now = () => PIN
  setTimeZoneSource(() => zone)
  try { return fn() } finally { Date.now = real; setTimeZoneSource(() => '') }
}

describe('calToday: the viewer\'s day', () => {
  it('pinned Sunday 21:30Z is Monday at +03, Sunday at UTC and New York', () => {
    assert.equal(pinned('Europe/Helsinki', () => calToday()), '2026-10-12')
    assert.equal(pinned('UTC', () => calToday()), '2026-10-11')
    assert.equal(pinned('America/New_York', () => calToday()), '2026-10-11')
    assert.equal(pinned('Europe/Helsinki', () => calToday(Date.UTC(2026, 9, 12, 20, 59))), '2026-10-12')
    assert.equal(pinned('Europe/Helsinki', () => calToday(Date.UTC(2026, 9, 12, 21, 0))), '2026-10-13')
  })
  it('CONTROL: the UTC day at the same clock is the day before', () => {
    assert.equal(pinned('Europe/Helsinki', () => calIsoDay(Date.now())), '2026-10-11')
  })
})

describe('pages/calendar.vue: the default week is the viewer\'s', () => {
  const src = read('src/pages/calendar.vue')
  it('today is calToday(), not the UTC day of now', () => {
    assert.match(src, /const today = calToday\(\)/)
    assert.doesNotMatch(src, /calIsoDay\(Date\.now\(\)\)/)
  })
})

describe('CalendarPhone: the fetch holds the viewer\'s days', () => {
  const src = read('src/components/CalendarPhone.vue')
  it('fetchRange asks calLoadWindow, not the UTC midnights of the range', () => {
    assert.match(src, /calLoadWindow\(r\.from, r\.to\)/)
    assert.doesNotMatch(src, /\$\{r\.(from|to)\}T00:00:00Z/)
  })
  it('the Day view of local Monday at +03 holds Monday 00:30 local', () => {
    const today = pinned('Europe/Helsinki', () => calToday())
    const r = calPhoneRange('day', today)
    const w = calLoadWindow(r.from, r.to)
    assert.ok(Date.parse(w.start) <= PIN && PIN < Date.parse(w.end), JSON.stringify(w))
    /* CONTROL: the old window [from 00:00Z, to 00:00Z) misses it */
    assert.ok(PIN < Date.parse(`${r.from}T00:00:00Z`))
  })
})

describe('pages/public-calendar.vue: today is the viewer\'s', () => {
  const src = read('src/pages/public-calendar.vue')
  it('today is calToday(), not the UTC slice of now', () => {
    assert.match(src, /const today = calToday\(\)/)
    assert.doesNotMatch(src, /new Date\(\)\.toISOString\(\)\.slice\(0, 10\)/)
  })
  it('the shown month is the viewer\'s on the 1st just after local midnight', () => {
    /* Sunday 2026-10-31 21:30Z = Sunday 2026-11-01 00:30 at +02 (EET) */
    assert.equal(pinned('Europe/Helsinki', () => calToday(Date.UTC(2026, 9, 31, 22, 30))).slice(0, 7), '2026-11')
    assert.equal(calIsoDay(Date.UTC(2026, 9, 31, 22, 30)).slice(0, 7), '2026-10')
  })
})
