// spec 097 T013 (G1): the pure half of drag to move / resize / create
// (src/utils/calendar-drag.mjs) and the If-Match write (calendar-events-api).
// - a move keeps the event's length, snaps to 15 minutes, stays in the day
// - the Week list moves between days only (the clock stays)
// - an all-day event moves by whole UTC days
// - a resize never leaves less than 15 minutes; 24:00 is the next midnight
// - a drag on empty time is a span; a plain hold is one hour
// - overlapping events sit side by side
// - the mock workspace refuses a stale If-Match with 409 edit_conflict and
//   the current event, as the hub does (spec 4.2, AC-02)
import { afterEach, beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { setTimeZoneSource } from '../../src/utils/date-iso.mjs'
import {
  calCreateSlot, calDayLayout, calDragErrorKey, calHhmm, calMinuteOf, calMoveTo, calResizeTo, calSameTimes, calSnap,
} from '../../src/utils/calendar-drag.mjs'
import { calendarUpdate } from '../../src/utils/calendar-events-api.mjs'
import { mockCalendarCreate } from '../../src/utils/calendar-mock.mjs'

const ev = (fields = {}) => ({
  id: 'e1', source: 'event', title: 'Standup', all_day: false,
  starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T09:30:00Z', updated_at: '2026-10-01T00:00:00Z', ...fields,
})

beforeEach(() => setTimeZoneSource(() => 'UTC'))
afterEach(() => setTimeZoneSource(() => ''))

describe('minutes', () => {
  it('reads and prints the viewer clock', () => {
    assert.equal(calMinuteOf('2026-10-07T09:45:00Z'), 585)
    assert.equal(calHhmm(585), '09:45')
    assert.ok(Number.isNaN(calMinuteOf('nope')))
  })
  it('snaps to 15 minutes inside the bounds', () => {
    assert.equal(calSnap(592), 585)
    assert.equal(calSnap(593), 600)
    assert.equal(calSnap(-20), 0)
    assert.equal(calSnap(1500), 1440)
    assert.equal(calSnap(1439, 0, 1425), 1425)
  })
  it('follows the viewer zone, not UTC', () => {
    setTimeZoneSource(() => 'Europe/Helsinki')
    assert.equal(calMinuteOf('2026-10-07T09:00:00Z'), 12 * 60)
    assert.deepEqual(calMoveTo(ev(), '2026-10-08', 14 * 60), { starts_at: '2026-10-08T11:00:00Z', ends_at: '2026-10-08T11:30:00Z' })
  })
})

describe('move', () => {
  it('keeps the length on a new day and time', () => {
    assert.deepEqual(calMoveTo(ev(), '2026-10-09', 13 * 60 + 15), { starts_at: '2026-10-09T13:15:00Z', ends_at: '2026-10-09T13:45:00Z' })
  })
  it('the Week list keeps the clock', () => {
    assert.deepEqual(calMoveTo(ev(), '2026-10-05', null), { starts_at: '2026-10-05T09:00:00Z', ends_at: '2026-10-05T09:30:00Z' })
  })
  it('never starts after 23:45', () => {
    assert.equal(calMoveTo(ev(), '2026-10-07', 1440)?.starts_at, '2026-10-07T23:45:00Z')
  })
  it('an all-day event moves by whole days and keeps its span', () => {
    const d = ev({ all_day: true, starts_at: '2026-10-07T00:00:00Z', ends_at: '2026-10-09T00:00:00Z' })
    assert.deepEqual(calMoveTo(d, '2026-10-10', 600), { starts_at: '2026-10-10T00:00:00Z', ends_at: '2026-10-12T00:00:00Z' })
  })
  it('null when the event has no time', () => {
    assert.equal(calMoveTo(ev({ starts_at: '' }), '2026-10-07', 60), null)
  })
  it('a move to the same place is no change', () => {
    const e = ev()
    assert.ok(calSameTimes(e, calMoveTo(e, '2026-10-07', 540)))
    assert.ok(!calSameTimes(e, calMoveTo(e, '2026-10-07', 555)))
  })
})

describe('resize', () => {
  it('sets the end on the start day', () => {
    assert.deepEqual(calResizeTo(ev(), 11 * 60), { starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T11:00:00Z' })
  })
  it('never shorter than 15 minutes', () => {
    assert.equal(calResizeTo(ev(), 8 * 60)?.ends_at, '2026-10-07T09:15:00Z')
  })
  it('24:00 is the next midnight', () => {
    assert.equal(calResizeTo(ev(), 1440)?.ends_at, '2026-10-08T00:00:00Z')
  })
  it('an all-day event has no bottom edge', () => {
    assert.equal(calResizeTo(ev({ all_day: true }), 600), null)
  })
})

describe('create', () => {
  it('a drag is its span, either way round', () => {
    assert.deepEqual(calCreateSlot(600, 690), { start: '10:00', end: '11:30' })
    assert.deepEqual(calCreateSlot(690, 600), { start: '10:00', end: '11:30' })
  })
  it('a hold without a drag is one hour', () => {
    assert.deepEqual(calCreateSlot(600, 600), { start: '10:00', end: '11:00' })
  })
  it('stays inside the day', () => {
    assert.deepEqual(calCreateSlot(1425, 1425), { start: '23:30', end: '23:59' })
  })
})

describe('layout', () => {
  it('places by clock, overlaps side by side, a later one alone again', () => {
    const out = calDayLayout([
      ev({ id: 'a', starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T10:00:00Z' }),
      ev({ id: 'b', starts_at: '2026-10-07T09:30:00Z', ends_at: '2026-10-07T10:30:00Z' }),
      ev({ id: 'c', starts_at: '2026-10-07T12:00:00Z', ends_at: '2026-10-07T12:00:00Z' }),
    ])
    assert.deepEqual(out.map((b) => [b.ev.id, b.top, b.len, b.col, b.cols]), [
      ['a', 540, 60, 0, 2], ['b', 570, 60, 1, 2], ['c', 720, 15, 0, 1],
    ])
  })
  it('an event past midnight is cut at the end of the day', () => {
    const [b] = calDayLayout([ev({ starts_at: '2026-10-07T23:00:00Z', ends_at: '2026-10-08T02:00:00Z' })])
    assert.equal(b.top + b.len, 1440)
  })
})

describe('refusals', () => {
  it('409 is the conflict notice, the rest the dialog words', () => {
    assert.equal(calDragErrorKey({ status: 409, token: 'edit_conflict' }), 'calendar_event.drag_conflict')
    assert.equal(calDragErrorKey({ status: 403, token: 'private_owner_only' }), 'calendar_event.error_private_owner')
    assert.equal(calDragErrorKey({ status: 404 }), 'calendar_event.error_not_found')
    assert.equal(calDragErrorKey(new Error('offline')), 'calendar_event.error_save')
  })
})

describe('If-Match', () => {
  const store = new Map()
  beforeEach(() => {
    store.clear()
    globalThis.localStorage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)), removeItem: (k) => store.delete(k) }
  })
  afterEach(() => { delete globalThis.localStorage })
  const api = { mock: true }

  it('AC-02 in the mock: the second save with the same If-Match is 409 with the first one\'s result', async () => {
    const made = mockCalendarCreate({ title: 'Two tabs', starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T10:00:00Z' })
    const first = await calendarUpdate(api, made.id, { starts_at: '2026-10-07T11:00:00Z', ends_at: '2026-10-07T12:00:00Z' }, '2026-10-07', made.updated_at)
    assert.equal(first.starts_at, '2026-10-07T11:00:00Z')
    await new Promise((r) => setTimeout(r, 2))
    await assert.rejects(
      calendarUpdate(api, made.id, { starts_at: '2026-10-07T14:00:00Z', ends_at: '2026-10-07T15:00:00Z' }, '2026-10-07', made.updated_at),
      (e) => e.status === 409 && e.token === 'edit_conflict' && e.event?.starts_at === '2026-10-07T11:00:00Z',
    )
  })
  it('CONTROL without If-Match the save goes through (089 behaviour)', async () => {
    const made = mockCalendarCreate({ title: 'Old client', starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T10:00:00Z' })
    await calendarUpdate(api, made.id, { title: 'one' }, '2026-10-07', made.updated_at)
    const out = await calendarUpdate(api, made.id, { title: 'two' }, '2026-10-07')
    assert.equal(out.title, 'two')
  })
})
