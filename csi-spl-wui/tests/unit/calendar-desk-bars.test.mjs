// SPL-6491 (member HUM-5, topic 4f4748dd): the desktop calendar dropped a
// TIMED event over several days: CalendarMainView put every item on the day
// it starts only (calEventDay), so a 17-day event that began before the
// shown week was on no shown day, and a 2.3-day one was a 1-hour stub at
// 23:00 of its first day. Now such an event is one bar in the all-day strip
// across every shown day it covers (calDeskBars), and the desktop Month
// lists it on each of its days (calDeskByDay).
// Control: on the tree before SPL-6491 calDeskBars / calDeskByDay /
// calDeskSpans do not exist and the main view buckets by calEventDay, so
// this file FAILS.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { calDeskBars, calDeskByDay, calDeskDays, calDeskSpans } from '../../src/utils/calendar-desktop-view.mjs'

const main = readFileSync(new URL('../../src/components/CalendarMainView.vue', import.meta.url), 'utf8')
const Z = 'Europe/Amsterdam'
const ev = (id, starts_at, ends_at, all_day = false) => ({ id, title: id, starts_at, ends_at, all_day })
/* week 49 of 2026: Monday 11-30 .. Sunday 12-06 */
const WEEK = calDeskDays('week', '2026-12-04')
/* the member's two events (c-002's measurement, prd): 17 days from before
   the week, and 2.3 days from Friday night into the next week */
const LONG = ev('long', '2026-11-16T23:00:00Z', '2026-12-03T23:00:00Z')
const TRIP = ev('trip', '2026-12-04T22:00:00Z', '2026-12-07T04:40:00Z')
const pick = (r, id) => {
  const b = r.bars.find((x) => x.ev.id === id)
  return b && { from: b.from, to: b.to, lane: b.lane, before: b.before, after: b.after }
}

describe('calDeskSpans: what the time grid cannot hold (SPL-6491)', () => {
  it('a timed event over several days, or of 24 h and more, spans', () => {
    assert.equal(calDeskSpans(LONG, Z), true)
    assert.equal(calDeskSpans(TRIP, Z), true)
    /* 23 h crossing midnight: two wall days */
    assert.equal(calDeskSpans(ev('x', '2026-12-01T10:00:00Z', '2026-12-02T09:00:00Z'), Z), true)
    /* exactly 24 h, local 00:00 to 00:00: one wall day, still a bar */
    assert.equal(calDeskSpans(ev('x', '2026-12-01T23:00:00Z', '2026-12-02T23:00:00Z'), Z), true)
  })
  it('control: a short event, and one ending exactly at midnight, do not', () => {
    assert.equal(calDeskSpans(ev('x', '2026-12-01T10:00:00Z', '2026-12-01T11:00:00Z'), Z), false)
    /* 09:00 -> 00:00 local next day: the end day does not count */
    assert.equal(calDeskSpans(ev('x', '2026-12-01T08:00:00Z', '2026-12-01T23:00:00Z'), Z), false)
    /* a deadline (start = end) */
    assert.equal(calDeskSpans(ev('x', '2026-12-01T17:00:00Z', '2026-12-01T17:00:00Z'), Z), false)
  })
  it('an all-day event spans when it covers two UTC days or more, never by its zone', () => {
    assert.equal(calDeskSpans(ev('x', '2026-12-01T00:00:00Z', '2026-12-03T00:00:00Z', true), Z), true)
    assert.equal(calDeskSpans(ev('x', '2026-12-01T00:00:00Z', '2026-12-02T00:00:00Z', true), 'America/Los_Angeles'), false)
  })
})

describe('calDeskBars: one bar per event across the shown days (SPL-6491)', () => {
  it('an event starting before the week is a bar from Monday, marked as going on before', () => {
    assert.deepEqual(pick(calDeskBars([LONG], WEEK, Z), 'long'), { from: 0, to: 3, lane: 0, before: true, after: false })
  })
  it('an event ending after the week is a bar to Sunday, marked as going on after', () => {
    assert.deepEqual(pick(calDeskBars([TRIP], WEEK, Z), 'trip'), { from: 4, to: 6, lane: 0, before: false, after: true })
  })
  it('an event covering the whole week and more is cut at both ends', () => {
    const all = ev('all', '2026-11-20T10:00:00Z', '2026-12-10T10:00:00Z')
    assert.deepEqual(pick(calDeskBars([all], WEEK, Z), 'all'), { from: 0, to: 6, lane: 0, before: true, after: true })
  })
  it('an event inside the week is a bar over exactly its days', () => {
    const inside = ev('in', '2026-12-01T10:00:00Z', '2026-12-02T09:00:00Z')
    assert.deepEqual(pick(calDeskBars([inside], WEEK, Z), 'in'), { from: 1, to: 2, lane: 0, before: false, after: false })
  })
  it('an end exactly at midnight does not reach the next day', () => {
    const toMidnight = ev('mid', '2026-12-01T08:00:00Z', '2026-12-02T23:00:00Z')
    assert.deepEqual(pick(calDeskBars([toMidnight], WEEK, Z), 'mid'), { from: 1, to: 2, lane: 0, before: false, after: false })
  })
  it('the day it covers is the viewer\'s wall day: a zone moves the bar', () => {
    /* 22:00Z Friday is Saturday in Helsinki */
    assert.equal(pick(calDeskBars([TRIP], WEEK, 'Europe/Helsinki'), 'trip').from, 5)
    assert.equal(pick(calDeskBars([TRIP], WEEK, 'UTC'), 'trip').from, 4)
  })
  it('overlapping bars take separate lanes; a free lane is reused', () => {
    const inside = ev('in', '2026-12-01T10:00:00Z', '2026-12-02T09:00:00Z')
    const r = calDeskBars([TRIP, inside, LONG], WEEK, Z)
    assert.equal(r.lanes, 2)
    assert.equal(pick(r, 'long').lane, 0)
    assert.equal(pick(r, 'in').lane, 1)
    /* TRIP starts Friday, after LONG ends Thursday: back in lane 0 */
    assert.equal(pick(r, 'trip').lane, 0)
  })
  it('three bars over the same days take three lanes; a later one takes the first free lane (R7 N5)', () => {
    const a = ev('a', '2026-12-01T08:00:00Z', '2026-12-03T08:00:00Z')
    const b = ev('b', '2026-12-01T09:00:00Z', '2026-12-03T09:00:00Z')
    const c = ev('c', '2026-12-01T10:00:00Z', '2026-12-03T10:00:00Z')
    const d = ev('d', '2026-12-04T10:00:00Z', '2026-12-05T10:00:00Z')
    const r = calDeskBars([a, b, c, d], WEEK, Z)
    assert.equal(r.lanes, 3)
    assert.deepEqual(['a', 'b', 'c', 'd'].map((id) => pick(r, id).lane), [0, 1, 2, 0])
  })
  it('control: short events, single all-day ones and events outside the range make no bar', () => {
    const r = calDeskBars([
      ev('short', '2026-12-01T10:00:00Z', '2026-12-01T11:00:00Z'),
      ev('day', '2026-12-02T00:00:00Z', '2026-12-03T00:00:00Z', true),
      ev('later', '2026-12-10T10:00:00Z', '2026-12-12T10:00:00Z'),
    ], WEEK, Z)
    assert.deepEqual(r, { bars: [], lanes: 0 })
  })
  it('a DST change week: a 25 h local day is a bar, a 23 h one is not; a span over the change keeps its wall days', () => {
    /* Amsterdam leaves DST on Sunday 2026-10-25; week 43 is 10-19 .. 10-25 */
    const wk = calDeskDays('week', '2026-10-21')
    const long25 = ev('d25', '2026-10-24T22:00:00Z', '2026-10-25T23:00:00Z')
    assert.deepEqual(pick(calDeskBars([long25], wk, Z), 'd25'), { from: 6, to: 6, lane: 0, before: false, after: false })
    const over = ev('over', '2026-10-24T10:00:00Z', '2026-10-26T11:00:00Z')
    assert.deepEqual(pick(calDeskBars([over], wk, Z), 'over'), { from: 5, to: 6, lane: 0, before: false, after: true })
    /* and it enters DST on Sunday 2026-03-29: local 00:00 -> 00:00 is 23 h, one day */
    const short23 = ev('d23', '2026-03-28T23:00:00Z', '2026-03-29T22:00:00Z')
    assert.equal(calDeskSpans(short23, Z), false)
  })
  it('3 days and Day cut the same way', () => {
    assert.deepEqual(pick(calDeskBars([LONG], calDeskDays('3day', '2026-12-02'), Z), 'long'), { from: 0, to: 2, lane: 0, before: true, after: false })
    assert.deepEqual(pick(calDeskBars([TRIP], calDeskDays('day', '2026-12-05'), Z), 'trip'), { from: 0, to: 0, lane: 0, before: true, after: true })
  })
})

describe('calDeskByDay: the desktop Month (SPL-6491)', () => {
  it('a spanning event is on every day it covers; a short one on its first day only', () => {
    const short = ev('short', '2026-12-01T10:00:00Z', '2026-12-01T11:00:00Z')
    const m = calDeskByDay([LONG, short], Z)
    assert.deepEqual([...m.keys()].filter((d) => m.get(d).some((x) => x.id === 'long')).length, 17)
    assert.ok(m.get('2026-11-30').some((x) => x.id === 'long'))
    assert.ok(m.get('2026-12-03').some((x) => x.id === 'long'))
    assert.equal(m.get('2026-12-04'), undefined)
    assert.deepEqual(m.get('2026-12-01').map((x) => x.id), ['long', 'short'])
  })
})

describe('CalendarMainView draws the bars (SPL-6491)', () => {
  it('buckets with calDeskByDay, draws calDeskBars, keeps spanning events off the time grid', () => {
    assert.match(main, /calDeskByDay\(items\.value\)/)
    assert.match(main, /calDeskBars\(items\.value, shown\.value\)/)
    assert.match(main, /data-test="calendar-week-bars"/)
    assert.match(main, /!ev\.all_day && !spans\.value\.has\(ev\.id\)/)
  })
})
