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
    ...fields,
  }
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
  return [
    item({ id: '00000000-0000-4000-8000-000000000101', title: 'Release', kind: 'release', starts_at: at(0, '09:00'), ends_at: at(0, '10:00'), release_version: 'v1.4.0' }),
    item({ id: '00000000-0000-4000-8000-000000000102', title: 'Database maintenance', kind: 'maintenance', starts_at: at(2, '10:00'), ends_at: at(2, '11:00'), creator_type: 'agent', creator_id: 'c-007' }),
    item({ id: 'SPL-12', source: 'issue', title: 'Issue deadline', kind: 'deadline', starts_at: at(2, '17:00'), ends_at: at(2, '17:00'), issue_key: 'SPL-12' }),
    item({ id: '00000000-0000-4000-8000-000000000103', title: 'Planning', kind: 'other', starts_at: at(30, '13:00'), ends_at: at(30, '14:00') }),
    item({ id: `official:XX:${year}-12-25`, source: 'official_day', title: 'Official day', description: '', kind: 'official_day', starts_at: `${year}-12-25T00:00:00Z`, ends_at: `${calAddDays(`${year}-12-25`, 1)}T00:00:00Z`, all_day: true, creator_type: 'system', creator_id: '', created_at: '', updated_at: '' }),
  ]
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
