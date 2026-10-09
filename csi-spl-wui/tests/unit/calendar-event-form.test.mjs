// spec 089 T008 v1 (owner msg 72db6282): the event dialog's form rules
// (src/utils/calendar-event-form.mjs) and the mock workspace's writes.
// - a new event is workspace; the Private switch makes it private (089 4.2)
// - the switch is the creator's only; an unknown viewer gets none (FR-010)
// - an edit sends only what changed, and never `audience` unless the switch
//   moved, so a non-creator's save cannot touch it
// - a timed event's clock is the viewer's zone, all-day is whole UTC days
// - the mock's PATCH refuses `private` from a non-creator like the hub (403)
// 097 T014 (G6..G9, G11):
// - a new event's zone is the member's preference; the clock is wall time in
//   the event's own zone; an 089 event (`UTC`) opens in the viewer's and
//   keeps `UTC` until the picker moves
// - a reminder amount keeps digits only (1.5, 0, -1 cannot be typed); up to
//   5 reminders, each at most 4 weeks; equal ones once
// - location and one of the 11 colours; Duplicate keeps every field
// rdb 0158 (owner t1 a3ce2031) and the rename (msg bad3799a, rdb 0159):
// workspace is everyone in the workspace (was public), public the internet
// (was web). The Public switch:
// - never on by default: a new event, a Duplicate (even of a public event)
//   and an event of another audience open with it off
// - create and edit send the public audience only when it is on, as `web`
//   while the hub is at rename step 1 (it reads `public` as workspace); an
//   event stored as `public` or `web` opens with it on; off is `workspace`;
//   Private wins over it; the two switches exclude each other
// - the mock workspace is the step-1 hub: `public` in is workspace, it
//   keeps `web` and answers the signed-out read with web events only
import { afterEach, beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { setTimeZoneSource } from '../../src/utils/date-iso.mjs'
import {
  CAL_COLORS, CAL_PUBLIC_WIRE, calAudienceSwitched, calCanSetPrivate, calEditable, calFormBody, calFormCopy, calFormFromEvent, calHourAfter, calIsPublic, calNewReminder,
  calReminderAmount, calReminderError, calRoadmapHref, calStored, calSynced, calWallToUtc,
} from '../../src/utils/calendar-event-form.mjs'
import { mockCalendarCreate, mockCalendarDelete, mockCalendarEvents, mockCalendarUpdate, mockWebCalendarEvents } from '../../src/utils/calendar-mock.mjs'

const ev = (fields = {}) => ({
  id: 'e1', source: 'event', title: 'Standup', description: '', kind: 'other',
  starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T09:30:00Z', all_day: false,
  audience: 'workspace', mentions: [], creator_type: 'human', creator_id: 'HUM-1', remind_at: '',
  topic_id: '', release_version: '', issue_key: '', created_at: '', updated_at: '', ...fields,
})

beforeEach(() => setTimeZoneSource(() => 'UTC'))
afterEach(() => setTimeZoneSource(() => ''))

describe('create', () => {
  it('a new event is 09:00-10:00 on the clicked day, workspace', () => {
    const form = calFormFromEvent(null, '2026-10-07')
    assert.deepEqual(form, {
      title: '', date: '2026-10-07', start: '09:00', end: '10:00', allDay: false, endDays: 0,
      timeZone: 'UTC', zoneWas: 'UTC', location: '', reminders: [], color: '', private: false, public: false, description: '',
    })
    form.title = '  Planning  '
    assert.deepEqual(calFormBody(form), {
      body: {
        title: 'Planning', starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T10:00:00Z', all_day: false, time_zone: 'UTC',
        location: '', reminders: [], color: '', audience: 'workspace', description: '',
      },
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
    assert.deepEqual(calFormBody({ ...calFormFromEvent(e, ''), private: false }, e).body, { audience: 'workspace' })
    const pub = ev()
    assert.deepEqual(calFormBody({ ...calFormFromEvent(pub, ''), private: true }, pub).body, { audience: 'private' })
    const internal = ev({ audience: 'internal' })
    assert.deepEqual(calFormBody({ ...calFormFromEvent(internal, ''), title: 'x' }, internal).body, { title: 'x' })
  })
})

describe('rdb 0158 + the rename (rdb 0159): the Public switch', () => {
  it('never the default: a new event is workspace with Public off', () => {
    const form = { ...calFormFromEvent(null, '2026-10-07'), title: 'Open day' }
    assert.equal(form.public, false)
    assert.equal(calFormBody(form).body.audience, 'workspace')
    for (const e of [ev(), ev({ audience: 'private' }), ev({ audience: 'internal' })]) assert.equal(calFormFromEvent(e, '').public, false, e.audience)
  })
  it('create: Public on sends the public audience under the name the step-1 hub takes (web)', () => {
    const form = { ...calFormFromEvent(null, '2026-10-07'), title: 'Open day', public: true }
    assert.equal(CAL_PUBLIC_WIRE, 'web')
    assert.equal(calFormBody(form).body.audience, CAL_PUBLIC_WIRE)
    assert.notEqual(calFormBody(form).body.audience, 'public', 'a step-1 hub reads public as workspace')
  })
  it('both names of the public audience open with Public on; untouched they send nothing', () => {
    for (const name of ['public', 'web']) {
      const pub = ev({ audience: name })
      const f = calFormFromEvent(pub, '')
      assert.equal(f.public, true, name)
      assert.equal(calIsPublic(pub), true, name)
      assert.deepEqual(calFormBody(f, pub), { body: null }, name)
      assert.deepEqual(calFormBody({ ...f, title: 'x' }, pub).body, { title: 'x' }, name)
      assert.deepEqual(calFormBody({ ...f, public: false }, pub).body, { audience: 'workspace' }, name)
      assert.deepEqual(calFormBody({ ...f, public: false, private: true }, pub).body, { audience: 'private' }, name)
    }
    assert.equal(calIsPublic(ev()), false)
  })
  it('edit: Public on a workspace or internal event sends the public audience', () => {
    const ws = ev()
    assert.deepEqual(calFormBody({ ...calFormFromEvent(ws, ''), public: true }, ws).body, { audience: CAL_PUBLIC_WIRE })
    const internal = ev({ audience: 'internal' })
    assert.deepEqual(calFormBody({ ...calFormFromEvent(internal, ''), public: true }, internal).body, { audience: CAL_PUBLIC_WIRE })
  })
  it('Private wins over Public; switching one on turns the other off', () => {
    const form = { ...calFormFromEvent(null, '2026-10-07'), title: 'x', private: true, public: true }
    assert.equal(calFormBody(form).body.audience, 'private')
    assert.deepEqual([calAudienceSwitched(form, 'private').private, calAudienceSwitched(form, 'private').public], [true, false])
    assert.deepEqual([calAudienceSwitched(form, 'public').private, calAudienceSwitched(form, 'public').public], [false, true])
    const off = { ...form, private: false, public: false }
    assert.equal(calAudienceSwitched(off, 'public'), off)
  })
  it('Duplicate of a public event keeps every field but Public: the copy is workspace', () => {
    const pub = ev({ audience: 'public', title: 'Open day', location: 'Hall' })
    const copy = calFormCopy(pub, '')
    assert.equal(copy.public, false)
    assert.equal(copy.location, 'Hall')
    assert.equal(calFormBody(copy).body.audience, 'workspace')
  })
})

describe('097 T014: time zone', () => {
  it('a new event takes the member\'s zone; its clock is wall time there', () => {
    setTimeZoneSource(() => 'Europe/Helsinki')
    const form = { ...calFormFromEvent(null, '2026-10-07'), title: 'x' }
    assert.equal(form.timeZone, 'Europe/Helsinki')
    const { body } = calFormBody({ ...form, timeZone: 'America/New_York' })
    assert.equal(body.time_zone, 'America/New_York')
    assert.equal(body.starts_at, '2026-10-07T13:00:00Z')
    assert.equal(calWallToUtc('2026-10-07', '09:00', 'Asia/Tokyo'), '2026-10-07T00:00:00Z')
  })
  it('an event opens in its own zone; an 089 (UTC) one in the viewer\'s, unchanged', () => {
    setTimeZoneSource(() => 'Europe/Helsinki')
    const ny = ev({ time_zone: 'America/New_York', starts_at: '2026-10-07T13:00:00Z', ends_at: '2026-10-07T14:00:00Z' })
    const f = calFormFromEvent(ny, '')
    assert.deepEqual([f.timeZone, f.date, f.start, f.end], ['America/New_York', '2026-10-07', '09:00', '10:00'])
    assert.equal(calFormBody(f, ny).body, null)
    const old = ev({ time_zone: 'UTC' })
    const g = calFormFromEvent(old, '')
    assert.deepEqual([g.timeZone, g.start], ['Europe/Helsinki', '12:00'])
    assert.equal(calFormBody(g, old).body, null)
    /* the picker moved: the zone is sent, the wall clock stays, so the instant moves */
    assert.deepEqual(calFormBody({ ...g, timeZone: 'UTC' }, old).body, {
      starts_at: '2026-10-07T12:00:00Z', ends_at: '2026-10-07T12:30:00Z', time_zone: 'UTC',
    })
  })
})

describe('097 T014: reminders, location, colour', () => {
  it('an amount keeps digits only: a fraction, a sign or 0 cannot be typed', () => {
    assert.equal(calReminderAmount('1.5'), '15')
    assert.equal(calReminderAmount('0'), '')
    assert.equal(calReminderAmount('007'), '7')
    assert.equal(calReminderAmount('-3'), '3')
    assert.equal(calReminderAmount('1e3'), '13')
    assert.equal(calReminderAmount('123456'), '12345')
  })
  it('a row is a whole number 1 or more, at most 4 weeks', () => {
    assert.equal(calReminderError({ amount: '10', unit: 'minutes' }), '')
    assert.equal(calReminderError({ amount: '', unit: 'minutes' }), 'calendar_event.error_reminder_amount')
    assert.equal(calReminderError({ amount: '1.5', unit: 'hours' }), 'calendar_event.error_reminder_amount')
    assert.equal(calReminderError({ amount: '0', unit: 'days' }), 'calendar_event.error_reminder_amount')
    assert.equal(calReminderError({ amount: '28', unit: 'days' }), '')
    assert.equal(calReminderError({ amount: '29', unit: 'days' }), 'calendar_event.error_reminder_max')
    assert.equal(calReminderError({ amount: '673', unit: 'hours' }), 'calendar_event.error_reminder_max')
    assert.equal(calReminderError({ amount: '40321', unit: 'minutes' }), 'calendar_event.error_reminder_max')
    assert.equal(calReminderError({ amount: '1', unit: 'weeks' }), 'calendar_event.error_reminder_amount')
  })
  it('up to 5; sent as typed, equal ones once; a bad one refuses the save', () => {
    const rows = []
    for (let i = 0; i < 5; i++) rows.push(calNewReminder(rows))
    assert.equal(calNewReminder(rows), null)
    const base = { ...calFormFromEvent(null, '2026-10-07'), title: 'x' }
    const out = calFormBody({ ...base, reminders: [{ amount: '1', unit: 'days' }, { amount: '10', unit: 'minutes' }, { amount: '1', unit: 'days' }] })
    assert.deepEqual(out.body.reminders, [{ amount: 1, unit: 'days', method: 'popup' }, { amount: 10, unit: 'minutes', method: 'popup' }])
    assert.equal(calFormBody({ ...base, reminders: [{ amount: '0', unit: 'days' }] }).error, 'calendar_event.error_reminder_amount')
    assert.equal(calFormBody({ ...base, reminders: [...rows, { amount: '1', unit: 'days' }] }).error, 'calendar_event.error_reminders_many')
  })
  it('an edit sends reminders, location and colour only when they changed', () => {
    const e = ev({ reminders: [{ amount: 1, unit: 'days', method: 'popup' }], location: 'Room 1', color: 'sage' })
    const f = calFormFromEvent(e, '')
    assert.deepEqual(f.reminders, [{ amount: '1', unit: 'days' }])
    assert.deepEqual([f.location, f.color], ['Room 1', 'sage'])
    assert.equal(calFormBody(f, e).body, null)
    assert.deepEqual(calFormBody({ ...f, reminders: [] }, e).body, { reminders: [] })
    assert.deepEqual(calFormBody({ ...f, location: ' Room 2 ', color: '' }, e).body, { location: 'Room 2', color: '' })
    assert.equal(calFormBody({ ...f, location: 'x'.repeat(301) }, e).error, 'calendar_event.error_location_long')
  })
  it('a colour is one of the hub\'s 11 names, else the kind\'s own', () => {
    assert.equal(CAL_COLORS.length, 11)
    assert.equal(calFormFromEvent(ev({ color: 'red' }), '').color, '')
    assert.equal(calFormBody({ ...calFormFromEvent(null, '2026-10-07'), title: 'x', color: 'url(x)' }).body.color, '')
  })
  it('Duplicate: a copy of an event saves as a new one with its fields', () => {
    const e = ev({ title: 'Retro', location: 'Room 1', color: 'grape', reminders: [{ amount: 2, unit: 'hours', method: 'popup' }], description: 'notes' })
    const { body } = calFormBody(calFormFromEvent(e, ''))
    assert.deepEqual(body, {
      title: 'Retro', starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T09:30:00Z', all_day: false, time_zone: 'UTC',
      location: 'Room 1', reminders: [{ amount: 2, unit: 'hours', method: 'popup' }], color: 'grape', audience: 'workspace', description: 'notes',
    })
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
  it('specs/112 WUI-2: a synced event (source_key) opens its pop-over but is not edited', () => {
    const synced = ev({ source_key: 'goal:G01:deadline', roadmap_url: '/roadmap?ws=demo&goal=G01#spec-112' })
    assert.equal(calSynced(synced), true)
    assert.equal(calStored(synced), true)
    assert.equal(calEditable(synced), false, 'control: a synced event that is editable turns this red')
    assert.equal(calSynced(ev({ source_key: '' })), false)
    assert.equal(calEditable(ev({ source_key: '' })), true)
    assert.equal(calStored(ev({ source: 'issue' })), false)
  })
  it('specs/112 WUI-2: the roadmap link is roadmap_url as given, a path of this site only', () => {
    assert.equal(calRoadmapHref(ev({ roadmap_url: '/roadmap?ws=demo&goal=G01#spec-112' })), '/roadmap?ws=demo&goal=G01#spec-112')
    assert.equal(calRoadmapHref(ev({ roadmap_url: 'https://example.com/roadmap' })), '')
    assert.equal(calRoadmapHref(ev({ roadmap_url: '//example.com/roadmap' })), '')
    assert.equal(calRoadmapHref(ev()), '')
    assert.equal(calRoadmapHref(null), '')
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

  it('create keeps all_day and audience; workspace by default, public taken as workspace', () => {
    const a = mockCalendarCreate({ title: 'A', starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T10:00:00Z' })
    const b = mockCalendarCreate({ title: 'B', starts_at: '2026-10-08T00:00:00Z', ends_at: '2026-10-09T00:00:00Z', all_day: true, audience: 'private' })
    assert.equal(a.audience, 'workspace')
    assert.equal(mockCalendarCreate({ title: 'C', starts_at: '2026-10-08T00:00:00Z', ends_at: '2026-10-08T01:00:00Z', audience: 'public' }).audience, 'workspace')
    assert.equal(b.audience, 'private')
    assert.equal(b.all_day, true)
    assert.deepEqual(week().filter((x) => x.title === 'A' || x.title === 'B').map((x) => x.audience), ['workspace', 'private'])
  })
  it('rdb 0158: create keeps web; the signed-out read answers web events only, five fields', () => {
    const w = mockCalendarCreate({ title: 'Open day', description: 'doors at 9', starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T12:00:00Z', audience: 'web' })
    mockCalendarCreate({ title: 'Board', starts_at: '2026-10-07T13:00:00Z', ends_at: '2026-10-07T14:00:00Z' })
    assert.equal(w.audience, 'web')
    const out = mockWebCalendarEvents('2026-10-05T00:00:00Z', '2026-10-12T00:00:00Z', today)
    assert.deepEqual(out, { events: [{ title: 'Open day', description: 'doors at 9', starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T12:00:00Z', all_day: false }] })
    assert.ok(week().some((x) => x.title === 'Board'), 'control: the workspace event is in the member read')
  })
  it('097 T014: create keeps time_zone, location, color and reminders', () => {
    const a = mockCalendarCreate({ title: 'A', starts_at: '2026-10-07T09:00:00Z', ends_at: '2026-10-07T10:00:00Z', time_zone: 'Europe/Helsinki', location: 'Room 1', color: 'sage', reminders: [{ amount: 10, unit: 'minutes', method: 'popup' }] })
    assert.deepEqual([a.time_zone, a.location, a.color, a.reminders.length], ['Europe/Helsinki', 'Room 1', 'sage', 1])
    const r = week().find((x) => x.kind === 'release')
    assert.deepEqual([r.time_zone, r.location, r.color, r.reminders], ['UTC', '', '', []])
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
  it('specs/112 HUB-1: a synced event is refused 409 synced_read_only, as the hub does', () => {
    const at = '2026-10-07T13:00:00Z'
    store.set('spool.mock.calendar-added', JSON.stringify([ev({ id: 's1', starts_at: at, ends_at: at, source_key: 'goal:G01:deadline' })]))
    const refused = (e) => e.status === 409 && e.token === 'synced_read_only'
    assert.throws(() => mockCalendarUpdate('s1', { title: 'x' }, today), refused)
    assert.throws(() => mockCalendarDelete('s1', today), refused)
    assert.equal(week().find((x) => x.id === 's1').title, 'Standup')
  })
})
