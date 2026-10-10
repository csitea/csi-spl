// t1 #spool-hub-ui 9dec05c3 (owner msg cbfaaefc): Copy link on a calendar
// event copies <origin>/calendar?d=<day>&event=<id>, the address spec 089
// T006 already opens. The path is roadmap-goals' goalCalendarHref; the day is
// the grid's (the viewer's wall day, an all-day event its UTC day).
import { afterEach, beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { setTimeZoneSource } from '../../src/utils/date-iso.mjs'
import { calEventLink } from '../../src/utils/calendar-event-link.mjs'

const ORIGIN = 'https://t1.example.com'

afterEach(() => setTimeZoneSource(() => ''))

describe('calEventLink', () => {
  beforeEach(() => setTimeZoneSource(() => 'UTC'))

  it('is the calendar on the event day with the event id', () => {
    const ev = { id: 'ev-1', all_day: false, starts_at: '2026-10-07T09:00:00Z' }
    assert.equal(calEventLink(ev, ORIGIN), 'https://t1.example.com/calendar?d=2026-10-07&event=ev-1')
  })

  it('encodes the id', () => {
    const ev = { id: 'a b&c', all_day: false, starts_at: '2026-10-07T09:00:00Z' }
    assert.equal(calEventLink(ev, ORIGIN), 'https://t1.example.com/calendar?d=2026-10-07&event=a%20b%26c')
  })

  it('an all-day event keeps its UTC day', () => {
    setTimeZoneSource(() => 'America/Los_Angeles')
    const ev = { id: 'ev-2', all_day: true, starts_at: '2026-10-07T00:00:00Z' }
    assert.equal(calEventLink(ev, ORIGIN), 'https://t1.example.com/calendar?d=2026-10-07&event=ev-2')
  })

  it('a timed event is on the viewer day', () => {
    setTimeZoneSource(() => 'Europe/Helsinki')
    const ev = { id: 'ev-3', all_day: false, starts_at: '2026-10-07T22:30:00Z' }
    assert.equal(calEventLink(ev, ORIGIN), 'https://t1.example.com/calendar?d=2026-10-08&event=ev-3')
  })

  it('no id or no start is no link', () => {
    assert.equal(calEventLink(null, ORIGIN), '')
    assert.equal(calEventLink({ id: '', starts_at: '2026-10-07T09:00:00Z' }, ORIGIN), '')
    assert.equal(calEventLink({ id: 'x', starts_at: '' }, ORIGIN), '')
  })
})
