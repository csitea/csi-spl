// spec 089 T008 v1 (owner msg 72db6282): the event dialog's form rules
// (src/utils/calendar-event-form.mjs) and the mock workspace's writes.
// - a new event is public; the Private switch makes it private (089 4.2)
// - the switch is the creator's only; an unknown viewer gets none (FR-010)
// - an edit sends only what changed, and never `audience` unless the switch
//   moved, so a non-creator's save cannot touch it
// - a timed event's clock is the viewer's zone, all-day is whole UTC days
// - the mock's PATCH refuses `private` from a non-creator like the hub (403)
import { afterEach, beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { setTimeZoneSource } from '../../src/utils/date-iso.mjs'
import {
  calCanSetPrivate, calEditable, calFormBody, calFormFromEvent, calHourAfter, calWallToUtc,
} from '../../src/utils/calendar-event-form.mjs'
import { mockCalendarCreate, mockCalendarDelete, mockCalendarEvents, mockCalendarUpdate } from '../../src/utils/calendar-mock.mjs'

const ev = (fields = {}) => ({
  id: 'e1', source: 'event', title: 'Standup', description: '', kind: 'other',
  starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T09:30:00Z', all_day: false,
  audience: 'public', mentions: [], creator_type: 'human', creator_id: 'HUM-1', remind_at: '',
  topic_id: '', release_version: '', issue_key: '', created_at: '', updated_at: '', ...fields,
})

beforeEach(() => setTimeZoneSource(() => 'UTC'))
afterEach(() => setTimeZoneSource(() => ''))

describe('create', () => {
  it('a new event is 09:00-10:00 on the clicked day, public', () => {
    const form = calFormFromEvent(null, '2026-10-07')
    assert.deepEqual(form, { title: '', date: '2026-10-07', start: '09:00', end: '10:00', allDay: false, endDays: 0, private: false, description: '' })
    form.title = '  Planning  '
    assert.deepEqual(calFormBody(form), {
      body: { title: 'Planning', starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T10:00:00Z', all_day: false, audience: 'public', description: '' },
    })
  })
  it('the Private switch on stores private', () => {
    const form = { ...calFormFromEvent(null, '2026-10-07'), title: 'Dentist', private: true }
    assert.equal(calFormBody(form).body.audience, 'private')
  })
  it('all day is [D 00:00Z, D+1 00:00Z)', () => {
    const form = { ...calFormFromEvent(null, '2026-12-31'), title: 'Freeze', allDay: true }
    const { body } = calFormBody(form)
    assert.equal(body.starts_at, '2026-12-31T00:00:00Z')
    assert.equal(body.ends_at, '2027-01-01T00:00:00Z')
    assert.equal(body.all_day, true)
  })
  it('refuses what the hub would refuse, with a catalogue key', () => {
    const base = { ...calFormFromEvent(null, '2026-10-07'), title: 'x' }
    assert.equal(calFormBody({ ...base, title: '   ' }).error, 'calendar_event.error_title')
    assert.equal(calFormBody({ ...base, title: 'x'.repeat(201) }).error, 'calendar_event.error_title_long')
    assert.equal(calFormBody({ ...base, description: 'x'.repeat(4001) }).error, 'calendar_event.error_description_long')
    assert.equal(calFormBody({ ...base, date: '' }).error, 'calendar_event.error_date')
    assert.equal(calFormBody({ ...base, start: '' }).error, 'calendar_event.error_time')
    assert.equal(calFormBody({ ...base, start: '11:00', end: '10:00' }).error, 'calendar_event.error_end')
    assert.equal(calFormBody({ ...base, title: 'x'.repeat(200), start: '10:00', end: '10:00' }).error, undefined)
  })
})

describe('viewer zone', () => {
  it('a wall time in the viewer zone becomes UTC, both ways round', () => {
    setTimeZoneSource(() => 'Europe/Helsinki')
    assert.equal(calWallToUtc('2026-10-07', '09:00'), '2026-10-07T06:00:00Z')
    assert.equal(calWallToUtc('2026-01-07', '09:00'), '2026-01-07T07:00:00Z')
    const form = calFormFromEvent(ev({ starts_at: '2026-10-06T22:30:00Z', ends_at: '2026-10-06T23:30:00Z' }), '')
    assert.equal(form.date, '2026-10-07')
    assert.equal(form.start, '01:30')
    assert.equal(form.end, '02:30')
    assert.equal(calFormBody(form, ev({ starts_at: '2026-10-06T22:30:00Z', ends_at: '2026-10-06T23:30:00Z' })).body, null)
  })
  it('not a date or a clock is ""', () => {
    assert.equal(calWallToUtc('2026-02-30', '09:00'), '')
    assert.equal(calWallToUtc('2026-10-07', '24:00'), '')
  })
})

describe('edit', () => {
  it('an unchanged form changes nothing', () => {
    for (const e of [ev(), ev({ all_day: true, starts_at: '2026-10-07T00:00:00Z', ends_at: '2026-10-09T00:00:00Z' }), ev({ audience: 'internal' })]) {
      assert.deepEqual(calFormBody(calFormFromEvent(e, ''), e), { body: null }, e.starts_at)
    }
  })
  it('only the changed fields are sent; a two-day event keeps its end day', () => {
    const e = ev({ ends_at: '2026-10-08T09:30:00Z' })
    const form = { ...calFormFromEvent(e, ''), title: 'Retro' }
    assert.equal(form.endDays, 1)
    assert.deepEqual(calFormBody(form, e).body, { title: 'Retro' })
  })
  it('audience is sent only when the switch moved', () => {
    const e = ev({ audience: 'private' })
    assert.deepEqual(calFormBody({ ...calFormFromEvent(e, ''), private: false }, e).body, { audience: 'public' })
    const pub = ev()
    assert.deepEqual(calFormBody({ ...calFormFromEvent(pub, ''), private: true }, pub).body, { audience: 'private' })
    const internal = ev({ audience: 'internal' })
    assert.deepEqual(calFormBody({ ...calFormFromEvent(internal, ''), title: 'x' }, internal).body, { title: 'x' })
  })
})

describe('who sees the switch, what opens', () => {
  it('the creator only, any viewer for a new event, nobody unknown', () => {
    assert.equal(calCanSetPrivate(null, ''), true)
    assert.equal(calCanSetPrivate(ev(), 'HUM-1'), true)
    assert.equal(calCanSetPrivate(ev(), 'HUM-2'), false)
    assert.equal(calCanSetPrivate(ev({ creator_type: 'agent', creator_id: 'c-007' }), 'HUM-1'), false)
    assert.equal(calCanSetPrivate(ev({ creator_id: '' }), ''), false)
  })
  it('a stored event opens; an issue deadline and an official day do not', () => {
    assert.equal(calEditable(ev()), true)
    assert.equal(calEditable(ev({ source: 'issue' })), false)
    assert.equal(calEditable(ev({ source: 'official_day' })), false)
    assert.equal(calEditable(null), false)
  })
  it('a moved start keeps an hour, capped at 23:59', () => {
    assert.equal(calHourAfter('09:15'), '10:15')
    assert.equal(calHourAfter('23:30'), '23:59')
  })
})

describe('mock workspace writes', () => {
  const store = new Map()
  beforeEach(() => {
    store.clear()
    globalThis.localStorage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)) }
  })
  afterEach(() => { delete globalThis.localStorage })
  const today = '2026-10-07'
  const week = () => mockCalendarEvents('2026-10-05T00:00:00Z', '2026-10-12T00:00:00Z', today).events

  it('create keeps all_day and audience; public by default', () => {
    const a = mockCalendarCreate({ title: 'A', starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T10:00:00Z' })
    const b = mockCalendarCreate({ title: 'B', starts_at: '2026-10-08T00:00:00Z', ends_at: '2026-10-09T00:00:00Z', all_day: true, audience: 'private' })
    assert.equal(a.audience, 'public')
    assert.equal(b.audience, 'private')
    assert.equal(b.all_day, true)
    assert.deepEqual(week().filter((x) => x.title === 'A' || x.title === 'B').map((x) => x.audience), ['public', 'private'])
  })
  it('edit and delete a seeded event; private is the creator\'s only (403)', () => {
    const release = week().find((x) => x.kind === 'release')
    const moved = mockCalendarUpdate(release.id, { title: 'Release 2', audience: 'private' }, today)
    assert.equal(moved.title, 'Release 2')
    assert.equal(week().filter((x) => x.id === release.id).length, 1)
    assert.equal(week().find((x) => x.id === release.id).audience, 'private')
    const agents = week().find((x) => x.creator_id === 'c-007')
    assert.throws(() => mockCalendarUpdate(agents.id, { audience: 'private' }, today), (e) => e.status === 403 && e.token === 'private_owner_only')
    assert.equal(mockCalendarUpdate(agents.id, { title: 'Maint' }, today).title, 'Maint')
    mockCalendarDelete(release.id, today)
    assert.equal(week().some((x) => x.id === release.id), false)
    assert.throws(() => mockCalendarDelete('SPL-12', today), (e) => e.status === 404)
  })
})
