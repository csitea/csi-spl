// spec 089 T007: the mock workspace's calendar (NUXT_PUBLIC_USE_MOCK), so the
// section and its e2e run without a hub. It answers the read routes in the
// wire format of spec 6.1 exactly: GET /v1/calendar/events and
// GET /v1/calendar/marks. Loaded lazily by the /calendar page only.

import { calAddDays, calDayMs, calIsoDay } from './calendar-year.mjs'

const STAMP = '2026-01-01T00:00:00Z'

/** One 6.1.1 event object with every field set, the given ones winning. */
function item(fields) {
  return {
    id: '',
    source: 'event',
    title: '',
    description: '',
    kind: 'other',
    starts_at: '',
    ends_at: '',
    all_day: false,
    audience: 'public',
    mentions: [],
    creator_type: 'human',
    creator_id: 'HUM-1',
    remind_at: '',
    topic_id: '',
    release_version: '',
    issue_key: '',
    created_at: STAMP,
    updated_at: STAMP,
    time_zone: 'UTC',
    location: '',
    color: '',
    reminders: [],
    ...fields,
  }
}

/* t1 b6c742f0: events the mock workspace created (a message's Add to
   calendar), kept in this browser only */
const ADDED_KEY = 'spool.mock.calendar-added'

function mockAddedEvents() {
  try {
    const list = JSON.parse(globalThis.localStorage?.getItem(ADDED_KEY) || '[]')
    return Array.isArray(list) ? list.map((x) => item(x)) : []
  } catch {
    return []
  }
}

/**
 * POST /v1/calendar/events (6.1.2) in the mock workspace: the created event,
 * kept so GET events / marks show it.
 * 097 T014: and the event's time_zone, location, color and reminders (spec 4.2).
 * @param {{ title?: string, description?: string, starts_at?: string, ends_at?: string, all_day?: boolean, audience?: string, topic_id?: string, time_zone?: string, location?: string, color?: string, reminders?: unknown[] }} body
 */
export function mockCalendarCreate(body = {}) {
  const now = new Date().toISOString()
  const ev = item({
    id: globalThis.crypto?.randomUUID?.() || `00000000-0000-4000-8000-${String(Date.now()).slice(-12).padStart(12, '0')}`,
    title: String(body.title || ''),
    description: String(body.description || ''),
    starts_at: String(body.starts_at || ''),
    ends_at: String(body.ends_at || ''),
    all_day: Boolean(body.all_day),
    audience: ['public', 'internal', 'private'].includes(String(body.audience)) ? String(body.audience) : 'public',
    topic_id: String(body.topic_id || ''),
    time_zone: String(body.time_zone || 'UTC'),
    location: String(body.location || ''),
    color: String(body.color || ''),
    reminders: Array.isArray(body.reminders) ? body.reminders : [],
    created_at: now,
    updated_at: now,
  })
  try {
    const raw = JSON.parse(globalThis.localStorage?.getItem(ADDED_KEY) || '[]')
    const list = Array.isArray(raw) ? raw : []
    globalThis.localStorage?.setItem(ADDED_KEY, JSON.stringify([...list, ev]))
  } catch { /* private mode: the event is returned, not kept */ }
  return ev
}

/* 089 T008: a seeded event the mock workspace edited or deleted is hidden by
   id; an edited one lives on in ADDED_KEY with its new fields */
const HIDDEN_KEY = 'spool.mock.calendar-hidden'

function mockHidden() {
  try {
    const list = JSON.parse(globalThis.localStorage?.getItem(HIDDEN_KEY) || '[]')
    return new Set(Array.isArray(list) ? list.map(String) : [])
  } catch {
    return new Set()
  }
}

function mockKeep(added, hidden) {
  try {
    globalThis.localStorage?.setItem(ADDED_KEY, JSON.stringify(added))
    globalThis.localStorage?.setItem(HIDDEN_KEY, JSON.stringify([...hidden]))
  } catch { /* private mode: nothing is kept */ }
}

/** The stored (source `event`) mock item `id`, or a 404 like the hub's. */
function mockFind(id, todayIso) {
  const ev = mockCalendarItems(todayIso).find((x) => x.id === id && x.source === 'event')
  if (!ev) throw Object.assign(new Error('calendar event 404'), { status: 404 })
  return ev
}

/**
 * PATCH /v1/calendar/events/{id} (6.1.2) in the mock workspace: the set
 * fields of `patch` over the event. Like the hub, only the event's creator
 * (the mock viewer is HUM-1) moves it to or from `private` (403).
 * @param {string} id
 * @param {Record<string, unknown>} patch
 * @param {string} todayIso
 */
export function mockCalendarUpdate(id, patch, todayIso) {
  const cur = mockFind(id, todayIso)
  const aud = patch.audience
  if (aud !== undefined && aud !== cur.audience && (aud === 'private' || cur.audience === 'private') && cur.creator_id !== 'HUM-1') {
    throw Object.assign(new Error('calendar event 403'), { status: 403, token: 'private_owner_only' })
  }
  const ev = { ...cur, ...patch, id, updated_at: new Date().toISOString() }
  const added = mockAddedEvents().filter((x) => x.id !== id)
  const hidden = mockHidden()
  hidden.add(id)
  mockKeep([...added, ev], hidden)
  return ev
}

/* 097 T017 (4.8): a delete is soft - the event goes to the trash with its
   deleted_at, and restore brings it back with the same id */
const TRASH_KEY = 'spool.mock.calendar-trash'
const TRASH_DAYS = 30

function mockTrashList() {
  try {
    const list = JSON.parse(globalThis.localStorage?.getItem(TRASH_KEY) || '[]')
    return Array.isArray(list) ? list.map((x) => item(x)) : []
  } catch {
    return []
  }
}

function mockKeepTrash(list) {
  try {
    globalThis.localStorage?.setItem(TRASH_KEY, JSON.stringify(list))
  } catch { /* private mode: nothing is kept */ }
}

/**
 * DELETE /v1/calendar/events/{id} (6.1.2, 4.8) in the mock workspace: the
 * event as it was; it waits in the trash.
 * @param {string} id
 * @param {string} todayIso
 */
export function mockCalendarDelete(id, todayIso) {
  const cur = mockFind(id, todayIso)
  const hidden = mockHidden()
  hidden.add(id)
  mockKeep(mockAddedEvents().filter((x) => x.id !== id), hidden)
  mockKeepTrash([{ ...cur, deleted_at: new Date().toISOString() }, ...mockTrashList().filter((x) => x.id !== id)])
  return cur
}

/**
 * POST /v1/calendar/events/{id}/restore (4.8) in the mock workspace: the
 * event back with the same id, or a 404 like the hub's when it is not in the trash.
 * @param {string} id
 */
export function mockCalendarRestore(id) {
  const trash = mockTrashList()
  const gone = trash.find((x) => x.id === id)
  if (!gone) throw Object.assign(new Error('calendar event 404'), { status: 404 })
  const { deleted_at: _deletedAt, ...ev } = gone
  mockKeepTrash(trash.filter((x) => x.id !== id))
  mockKeep([...mockAddedEvents().filter((x) => x.id !== id), ev], mockHidden())
  return ev
}

/**
 * GET /v1/calendar/trash (4.8) in the mock workspace: the events deleted in
 * the last 30 days, newest deletion first.
 * @param {number} [nowMs]
 */
export function mockCalendarTrash(nowMs = Date.now()) {
  const since = nowMs - TRASH_DAYS * 86400000
  return mockTrashList()
    .filter((x) => Date.parse(x.deleted_at) >= since)
    .sort((a, b) => b.deleted_at.localeCompare(a.deleted_at) || a.id.localeCompare(b.id))
}

/**
 * The mock items around `todayIso`: a release, a maintenance window, an issue
 * deadline this week, an event next month, and one official day (25 December
 * of today's year).
 * @param {string} todayIso
 * @returns {ReturnType<typeof item>[]}
 */
export function mockCalendarItems(todayIso) {
  const today = Number.isNaN(calDayMs(todayIso)) ? calIsoDay(Date.now()) : todayIso
  const at = (offset, hhmm) => `${calAddDays(today, offset)}T${hhmm}:00Z`
  const year = today.slice(0, 4)
  const hidden = mockHidden()
  const seeded = [
    item({ id: '00000000-0000-4000-8000-000000000101', title: 'Release', kind: 'release', starts_at: at(0, '09:00'), ends_at: at(0, '10:00'), release_version: 'v1.4.0' }),
    item({ id: '00000000-0000-4000-8000-000000000102', title: 'Database maintenance', kind: 'maintenance', starts_at: at(2, '10:00'), ends_at: at(2, '11:00'), creator_type: 'agent', creator_id: 'c-007' }),
    item({ id: 'SPL-12', source: 'issue', title: 'Issue deadline', kind: 'deadline', starts_at: at(2, '17:00'), ends_at: at(2, '17:00'), issue_key: 'SPL-12' }),
    item({ id: '00000000-0000-4000-8000-000000000103', title: 'Planning', kind: 'other', starts_at: at(30, '13:00'), ends_at: at(30, '14:00') }),
    item({ id: `official:XX:${year}-12-25`, source: 'official_day', title: 'Official day', description: '', kind: 'official_day', starts_at: `${year}-12-25T00:00:00Z`, ends_at: `${calAddDays(`${year}-12-25`, 1)}T00:00:00Z`, all_day: true, creator_type: 'system', creator_id: '', created_at: '', updated_at: '' }),
  ]
  return [...mockAddedEvents(), ...seeded.filter((x) => !hidden.has(x.id))]
}

/**
 * GET /v1/calendar/events?start=&end= (6.1.2): the items overlapping
 * [start, end), by starts_at then id.
 * @param {string} start RFC 3339
 * @param {string} end RFC 3339
 * @param {string} todayIso
 */
export function mockCalendarEvents(start, end, todayIso) {
  const s = Date.parse(start)
  const e = Date.parse(end)
  const events = mockCalendarItems(todayIso)
    .filter((x) => Date.parse(x.starts_at) < e && (Date.parse(x.ends_at) > s || (x.starts_at === x.ends_at && Date.parse(x.starts_at) >= s)))
    .sort((a, b) => a.starts_at.localeCompare(b.starts_at) || a.id.localeCompare(b.id))
  return { start, end, events }
}

/**
 * GET /v1/calendar/marks?start_year=&end_year= (6.1.2): per UTC day the count
 * and sorted kinds of the event and issue items, oldest first, and the
 * official days as tints.
 * @param {number} startYear
 * @param {number} endYear
 * @param {string} todayIso
 */
export function mockCalendarMarks(startYear, endYear, todayIso) {
  const inYears = (iso) => Number(iso.slice(0, 4)) >= startYear && Number(iso.slice(0, 4)) <= endYear
  const byDay = new Map()
  const official = []
  for (const x of mockCalendarItems(todayIso)) {
    const day = x.starts_at.slice(0, 10)
    if (!inYears(day)) continue
    if (x.source === 'official_day') { official.push({ day, title: x.title }); continue }
    const row = byDay.get(day) || { day, count: 0, kinds: [] }
    row.count++
    if (!row.kinds.includes(x.kind)) row.kinds.push(x.kind)
    byDay.set(day, row)
  }
  const days = [...byDay.values()].sort((a, b) => a.day.localeCompare(b.day)).map((r) => ({ ...r, kinds: r.kinds.sort() }))
  return { start_year: startYear, end_year: endYear, days, official_days: official.sort((a, b) => a.day.localeCompare(b.day)) }
}
