// spec 106 T002: the phone calendar's date arithmetic - period steps, the
// 6x7 Month grid across a year end and a leap February, the Week strip and
// its folded empty days, the header titles, the add sheet's presets, UTC
// all-day placement across zones (S4-3) and DST hour rows (S4-6). Each
// block carries a control: the case that must come out differently, so a
// helper that ignored its input could not pass.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  calPhoneDayHours, calPhoneEventDays, calPhoneFoldDays, calPhoneFoldLabel, calPhoneHourPreset,
  calPhoneMonthGrid, calPhoneNextFullHour, calPhoneRange, calPhoneSpanOf, calPhoneStep, calPhoneTitle,
  calPhoneWeekStrip,
} from '../../src/utils/calendar-phone-nav.mjs'

describe('period step', () => {
  it('month / week / day turn by one period, both ways', () => {
    assert.equal(calPhoneStep('day', '2026-12-31', 1), '2027-01-01')
    assert.equal(calPhoneStep('day', '2026-03-01', -1), '2026-02-28')
    assert.equal(calPhoneStep('week', '2026-12-28', 1), '2027-01-04')
    assert.equal(calPhoneStep('week', '2026-10-07', -1), '2026-09-30')
    assert.equal(calPhoneStep('month', '2026-12-15', 1), '2027-01-15')
    assert.equal(calPhoneStep('month', '2027-01-15', -1), '2026-12-15')
  })
  it('a month step clamps to the last day; a leap February keeps the 29th', () => {
    assert.equal(calPhoneStep('month', '2026-01-31', 1), '2026-02-28')
    assert.equal(calPhoneStep('month', '2028-01-31', 1), '2028-02-29')
    assert.equal(calPhoneStep('month', '2028-03-31', -1), '2028-02-29')
    /* control: a day that exists in the target month is not clamped */
    assert.equal(calPhoneStep('month', '2026-01-28', 1), '2026-02-28')
    assert.equal(calPhoneStep('month', '2026-01-15', 1), '2026-02-15')
  })
  it('junk is no day', () => {
    assert.equal(calPhoneStep('month', 'x', 1), '')
    assert.equal(calPhoneStep('year', '2026-10-07', 1), '')
    assert.equal(calPhoneStep('day', '2026-10-07', 0), '2026-10-07')
  })
})

describe('the 6x7 month grid', () => {
  it('is 42 Monday-first cells; across a year end the neighbours show', () => {
    const g = calPhoneMonthGrid('2026-12-10')
    assert.equal(g.length, 42)
    assert.deepEqual(g[0], { iso: '2026-11-30', d: 30, inMonth: false }, 'December 2026 starts on a Tuesday')
    assert.deepEqual(g[1], { iso: '2026-12-01', d: 1, inMonth: true })
    assert.deepEqual(g[31], { iso: '2026-12-31', d: 31, inMonth: true })
    assert.deepEqual(g[32], { iso: '2027-01-01', d: 1, inMonth: false })
    assert.equal(g[41].iso, '2027-01-10')
    assert.equal(g.filter((c) => c.inMonth).length, 31)
  })
  it('a leap February has 29 days in it, a common one 28 (control)', () => {
    const leap = calPhoneMonthGrid('2028-02-01')
    assert.equal(leap.filter((c) => c.inMonth).length, 29)
    assert.equal(leap.find((c) => c.inMonth && c.d === 29).iso, '2028-02-29')
    assert.equal(leap[0].iso, '2028-01-31', 'February 2028 starts on a Tuesday')
    const common = calPhoneMonthGrid('2026-02-14')
    assert.equal(common.filter((c) => c.inMonth).length, 28)
    assert.equal(common[0].iso, '2026-01-26', 'February 2026 starts on a Sunday: six days of January lead')
  })
  it('a month starting on Monday has no leading cell (control)', () => {
    assert.deepEqual(calPhoneMonthGrid('2026-06-20')[0], { iso: '2026-06-01', d: 1, inMonth: true })
    assert.deepEqual(calPhoneMonthGrid('nope'), [])
  })
  it('a view range is [from, to): the grid for Month, Monday..Sunday for Week', () => {
    assert.deepEqual(calPhoneRange('month', '2026-12-10'), { from: '2026-11-30', to: '2027-01-11' })
    assert.deepEqual(calPhoneRange('week', '2026-10-07'), { from: '2026-10-05', to: '2026-10-12' })
    assert.deepEqual(calPhoneRange('day', '2026-12-31'), { from: '2026-12-31', to: '2027-01-01' })
    assert.equal(calPhoneRange('year', '2026-10-07'), null)
  })
})

describe('the week strip and folded days', () => {
  it('the strip is the seven days, Monday first, across a year end', () => {
    const s = calPhoneWeekStrip('2027-01-01')
    assert.deepEqual(s.map((x) => x.iso), ['2026-12-28', '2026-12-29', '2026-12-30', '2026-12-31', '2027-01-01', '2027-01-02', '2027-01-03'])
    assert.deepEqual(s.map((x) => x.wd), [1, 2, 3, 4, 5, 6, 7])
    assert.equal(s[4].d, 1)
  })
  it('empty days fold into one row per run: Thu-Sat', () => {
    const days = calPhoneWeekStrip('2026-10-07').map((x) => x.iso)
    const busy = new Map([['2026-10-05', 2], ['2026-10-06', 1], ['2026-10-07', 1], ['2026-10-11', 3]])
    const rows = calPhoneFoldDays(days, (d) => busy.get(d) || 0)
    assert.deepEqual(rows.map((r) => r.kind), ['day', 'day', 'day', 'fold', 'day'])
    assert.deepEqual(rows[3], { kind: 'fold', from: '2026-10-08', to: '2026-10-10', days: ['2026-10-08', '2026-10-09', '2026-10-10'] })
    assert.equal(calPhoneFoldLabel(rows[3]), 'Thu-Sat')
    assert.equal(calPhoneFoldLabel(rows[3], ['ma', 'ti', 'ke', 'to', 'pe', 'la', 'su']), 'to-la')
  })
  it('control: a week with an event every day folds nothing; an empty week is one row', () => {
    const days = calPhoneWeekStrip('2026-10-07').map((x) => x.iso)
    assert.ok(calPhoneFoldDays(days, () => 1).every((r) => r.kind === 'day'))
    const empty = calPhoneFoldDays(days, () => 0)
    assert.equal(empty.length, 1)
    assert.equal(calPhoneFoldLabel(empty[0]), 'Mon-Sun')
  })
  it('an unfolded day (S2-7) stands alone and splits its run', () => {
    const days = calPhoneWeekStrip('2026-10-07').map((x) => x.iso)
    const rows = calPhoneFoldDays(days, (d) => (d === '2026-10-05' ? 1 : 0), new Set(['2026-10-09']))
    assert.deepEqual(rows.map((r) => (r.kind === 'fold' ? `fold ${calPhoneFoldLabel(r)}` : `${r.kind} ${r.iso}`)),
      ['day 2026-10-05', 'fold Tue-Thu', 'empty 2026-10-09', 'fold Sat-Sun'])
    assert.equal(calPhoneFoldLabel({ from: '2026-10-08', to: '2026-10-08' }), 'Thu')
  })
})

describe('the header title (spec 4.1)', () => {
  it('Month, Week, Day', () => {
    assert.equal(calPhoneTitle('month', '2026-10-07'), 'October 2026')
    assert.equal(calPhoneTitle('week', '2026-10-07'), '5-11 Oct 2026')
    assert.equal(calPhoneTitle('day', '2026-10-07'), 'Wed 2026-10-07')
  })
  it('a week across a month or a year names both ends (control: one month names one)', () => {
    assert.equal(calPhoneTitle('week', '2026-10-01'), '28 Sep - 4 Oct 2026')
    assert.equal(calPhoneTitle('week', '2027-01-01'), '28 Dec 2026 - 3 Jan 2027')
    assert.equal(calPhoneTitle('week', '2026-10-14'), '12-18 Oct 2026')
  })
  it('takes the locale names', () => {
    const months = ['tammikuu', 'helmikuu', 'maaliskuu', 'huhtikuu', 'toukokuu', 'kesäkuu', 'heinäkuu', 'elokuu', 'syyskuu', 'lokakuu', 'marraskuu', 'joulukuu']
    const weekdays = ['ma', 'ti', 'ke', 'to', 'pe', 'la', 'su']
    assert.equal(calPhoneTitle('month', '2026-10-07', { months }), 'lokakuu 2026')
    assert.equal(calPhoneTitle('day', '2026-10-07', { weekdays }), 'ke 2026-10-07')
    assert.equal(calPhoneTitle('week', '2026-10-07', { months, monthsShort: months.map((m) => `${m.slice(0, 4)}.`) }), '5-11 loka. 2026')
    assert.equal(calPhoneTitle('week', 'x'), '')
  })
})

describe('the add sheet presets (4.4)', () => {
  it('the next full hour, in the given zone', () => {
    assert.deepEqual(calPhoneNextFullHour('2026-10-07T14:01:00Z', 'UTC'), { date: '2026-10-07', start: '15:00', endDate: '2026-10-07', end: '16:00' })
    assert.deepEqual(calPhoneNextFullHour('2026-10-07T14:01:00Z', 'Europe/Helsinki'), { date: '2026-10-07', start: '18:00', endDate: '2026-10-07', end: '19:00' })
    /* control: on the hour it stays */
    assert.deepEqual(calPhoneNextFullHour('2026-10-07T14:00:00Z', 'UTC'), { date: '2026-10-07', start: '14:00', endDate: '2026-10-07', end: '15:00' })
  })
  it('late evening rolls over to the next day', () => {
    assert.deepEqual(calPhoneNextFullHour('2026-12-31T23:30:00Z', 'UTC'), { date: '2027-01-01', start: '00:00', endDate: '2027-01-01', end: '01:00' })
    assert.deepEqual(calPhoneNextFullHour('2026-10-07T22:10:00Z', 'UTC'), { date: '2026-10-07', start: '23:00', endDate: '2026-10-08', end: '00:00' })
    assert.equal(calPhoneNextFullHour('nope', 'UTC'), null)
  })
  it('a tapped hour', () => {
    assert.deepEqual(calPhoneHourPreset('2026-10-07', 14), { date: '2026-10-07', start: '14:00', endDate: '2026-10-07', end: '15:00' })
    assert.equal(calPhoneHourPreset('2026-10-07', 24), null)
    assert.equal(calPhoneHourPreset('x', 9), null)
  })
})

describe('UTC all-day placement (S4-3)', () => {
  const allDay = { starts_at: '2026-10-07T00:00:00Z', ends_at: '2026-10-08T00:00:00Z', all_day: true }
  it('an all-day event lands on its UTC date in every zone', () => {
    for (const zone of ['UTC', 'America/Los_Angeles', 'Pacific/Honolulu', 'Europe/Helsinki', 'Pacific/Kiritimati']) {
      assert.deepEqual(calPhoneEventDays(allDay, zone), ['2026-10-07'], zone)
    }
  })
  it('control: the same instants as a timed event move to the viewer\'s day', () => {
    const timed = { ...allDay, all_day: false }
    assert.deepEqual(calPhoneEventDays(timed, 'America/Los_Angeles'), ['2026-10-06', '2026-10-07'])
    assert.deepEqual(calPhoneEventDays(timed, 'UTC'), ['2026-10-07'])
  })
  it('a multi-day event covers every day; Day X of Y', () => {
    const three = { starts_at: '2026-12-30T00:00:00Z', ends_at: '2027-01-02T00:00:00Z', all_day: true }
    assert.deepEqual(calPhoneEventDays(three, 'America/Los_Angeles'), ['2026-12-30', '2026-12-31', '2027-01-01'])
    assert.deepEqual(calPhoneSpanOf(three, '2026-12-31', 'America/Los_Angeles'), { n: 2, of: 3 })
    assert.equal(calPhoneSpanOf(three, '2027-01-02'), null, 'the end day is exclusive')
    assert.equal(calPhoneSpanOf(allDay, '2026-10-07'), null, 'one day is no span')
  })
  it('a timed event ending at midnight does not touch the next day', () => {
    const ev = { starts_at: '2026-10-07T20:00:00Z', ends_at: '2026-10-08T00:00:00Z', all_day: false }
    assert.deepEqual(calPhoneEventDays(ev, 'UTC'), ['2026-10-07'])
    assert.deepEqual(calPhoneEventDays({ starts_at: 'x' }, 'UTC'), [])
  })
})

describe('DST hour rows (S4-6)', () => {
  const labels = (rows) => rows.map((r) => r.label)
  it('spring forward: 23 rows, the skipped hour absent', () => {
    const eu = calPhoneDayHours('2026-03-29', 'Europe/Helsinki')
    assert.equal(eu.length, 23)
    assert.ok(!labels(eu).includes('03:00'))
    assert.equal(calPhoneDayHours('2026-03-08', 'America/New_York').length, 23)
  })
  it('fall back: 25 rows, the repeated hour labelled twice, an hour apart', () => {
    const eu = calPhoneDayHours('2026-10-25', 'Europe/Helsinki')
    assert.equal(eu.length, 25)
    const twice = eu.filter((r) => r.label === '03:00')
    assert.equal(twice.length, 2)
    assert.equal(twice[1].at - twice[0].at, 3600000)
    assert.equal(calPhoneDayHours('2026-11-01', 'America/New_York').length, 25)
  })
  it('control: the day before, and a zone without DST, have 24', () => {
    const before = calPhoneDayHours('2026-10-24', 'Europe/Helsinki')
    assert.equal(before.length, 24)
    assert.deepEqual(labels(before).slice(0, 3), ['00:00', '01:00', '02:00'])
    assert.equal(before[0].at, Date.parse('2026-10-23T21:00:00Z'))
    assert.equal(calPhoneDayHours('2026-10-25', 'UTC').length, 24)
    const kolkata = calPhoneDayHours('2026-10-25', 'Asia/Kolkata')
    assert.equal(kolkata.length, 24)
    assert.equal(kolkata[0].label, '00:00', 'a :30 zone starts at its own midnight')
    assert.deepEqual(calPhoneDayHours('x', 'UTC'), [])
  })
})
