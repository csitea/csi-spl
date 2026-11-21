// SPL-6146 (owner HUM-10, t1 74772974, msg 3d289c5c): the calendar writes
// the ISO-8601 week as w-01 .. w-53, two digits, beside the day number - a
// label, never an event. calWeekLabel is the one helper every view calls.
// Control: on origin/master before SPL-6146 calendar-year.mjs exports no
// calWeekLabel, so every check FAILS.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import * as year from '../../src/utils/calendar-year.mjs'
import { calPhoneTitle } from '../../src/utils/calendar-phone-nav.mjs'

const label = (iso) => (typeof year.calWeekLabel === 'function' ? year.calWeekLabel(iso) : undefined)

describe('calWeekLabel: the ISO-8601 week as w-NN', () => {
  it('is exported', () => {
    assert.equal(typeof year.calWeekLabel, 'function')
  })
  it('two digits, ISO weeks (Monday first, the week holding Thursday)', () => {
    assert.equal(label('2027-01-04'), 'w-01', 'the first Monday of 2027')
    assert.equal(label('2027-01-10'), 'w-01', 'its Sunday')
    assert.equal(label('2026-12-28'), 'w-53', '2026 has 53 weeks')
    assert.equal(label('2027-01-03'), 'w-53', 'a January Sunday in the last week of 2026')
    assert.equal(label('2026-11-02'), 'w-45')
    assert.equal(label('2026-03-02'), 'w-10')
    assert.equal(label('2025-12-29'), 'w-01', 'a December Monday in the first week of 2026')
    assert.equal(label('2027-12-27'), 'w-52', '2027 has 52 weeks')
  })
  it('not a day: empty', () => {
    assert.equal(label('x'), '')
    assert.equal(label(''), '')
    assert.equal(label('2026-02-30'), '')
  })
  it('the phone Day header writes it after the date', () => {
    assert.equal(calPhoneTitle('day', '2026-10-07'), 'Wed 2026-10-07 w-41')
  })
})
