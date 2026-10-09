/**
 * Spec 107 v1.2 T015: the mock workspace's team side (lde and e2e; never in
 * a hub build's path), in the T008 / T009 shapes. A weekly period, Monday
 * first; three members with approved entries on the weekdays up to today.
 * A period is `frozen` from its end + 3 days (grace 2: a week freezes
 * Wednesday 00:00), else `open`; the biz owner's decisions live in memory
 * for the page's life, as the hub's rows would.
 */
import { hoursAddDays } from './hours-calendar.mjs'
import { HOURS_MOCK_TOPIC, HOURS_MOCK_TOPIC_2 } from './hours-calendar-mock.mjs'
import { hoursTargetKind } from './hours-team.mjs'

export const HOURS_TEAM_MOCK_MEMBERS = [
  { member_id: 'HUM-1', name: 'Member A' },
  { member_id: 'HUM-2', name: 'Member B' },
  { member_id: 'HUM-3', name: 'Member C' },
]

/** period start|member -> { state, note } */
const decided = new Map()

function monday(iso) {
  const wd = new Date(`${iso}T00:00:00Z`).getUTCDay()
  return hoursAddDays(iso, -((wd + 6) % 7))
}

/** a member's approved entries on a weekday (1 = Monday) */
function entriesOf(member, day, wd) {
  const e = (target, minutes, note = '') => ({ member_id: member, day, target, minutes, suggested_minutes: minutes, ...(note ? { note } : {}) })
  if (member === 'HUM-1') return [e(`t:${HOURS_MOCK_TOPIC}`, 240), e('cal:mock-weekly-sync', 60), e('ws', 30)]
  if (member === 'HUM-2') return [e(`t:${HOURS_MOCK_TOPIC_2}`, 180 + wd * 15, wd === 1 ? 'pairing' : ''), e('ch:lobby', 45)]
  return wd % 2 ? [e(`t:${HOURS_MOCK_TOPIC}`, 300)] : []
}

/** GET /v1/hours?period=day for a viewer whose today is `today`. */
export function mockTeamHours(day, today) {
  const start = monday(day)
  const end = hoursAddDays(start, 6)
  const freezes = hoursAddDays(end, 3)
  const clock = today >= freezes ? 'frozen' : 'open'
  const entries = []
  for (let i = 0; i < 5; i++) {
    const d = hoursAddDays(start, i)
    if (d > today) break
    for (const m of HOURS_TEAM_MOCK_MEMBERS) entries.push(...entriesOf(m.member_id, d, i + 1))
  }
  const members = HOURS_TEAM_MOCK_MEMBERS.map((m) => {
    const got = decided.get(`${start}|${m.member_id}`)
    const minutes = entries.filter((e) => e.member_id === m.member_id).reduce((n, e) => n + e.minutes, 0)
    return { ...m, state: got ? got.state : clock, minutes, period_minutes: minutes, ...(got && got.note ? { note: got.note } : {}) }
  })
  return { period: { start, end, freezes_at: `${freezes}T00:00:00Z` }, members, entries }
}

/** PUT /v1/hours/periods: as the hub (T008), all or none, only frozen rows move. */
export function mockDecideHours(body, today) {
  const action = body && body.action
  if (action !== 'approve' && action !== 'return') throw Object.assign(new Error('bad_hours'), { status: 400, token: 'bad_hours' })
  if (action === 'return' && !String(body.note || '').trim()) throw Object.assign(new Error('bad_hours'), { status: 400, token: 'bad_hours' })
  const view = mockTeamHours(body.period, today)
  const named = Array.isArray(body.members) && body.members.length ? body.members : null
  const rows = view.members.filter((m) => (named ? named.includes(m.member_id) : m.state === 'frozen'))
  if (named && (rows.length !== named.length || rows.some((m) => m.state !== 'frozen'))) {
    throw Object.assign(new Error('period_state'), { status: 409, token: 'period_state' })
  }
  for (const m of rows) {
    decided.set(`${view.period.start}|${m.member_id}`, { state: action === 'return' ? 'returned' : 'approved', note: action === 'return' ? String(body.note).trim() : '' })
  }
  return { ...mockTeamHours(body.period, today), changed: rows.length }
}

const COLUMNS = ['date', 'member_id', 'member_name', 'target_type', 'target_id', 'target_name', 'issue_key', 'minutes', 'hours_decimal', 'suggested_minutes', 'note', 'period_state', 'approved_by', 'approved_at']
const TYPES = { t: 'topic', ch: 'channel', dm: 'dm', cal: 'meeting', ws: 'other' }

/** GET /v1/hours/export: the CSV of the spec's columns (6.2); the mock's XLSX is the same text under the XLSX type. */
export function mockExportHours(day, format, final, today) {
  const view = mockTeamHours(day, today)
  const state = new Map(view.members.map((m) => [m.member_id, m.state]))
  const name = new Map(view.members.map((m) => [m.member_id, m.name]))
  const lines = [COLUMNS.join(',')]
  for (const e of view.entries) {
    const st = state.get(e.member_id)
    if (final && st !== 'approved') continue
    const kind = hoursTargetKind(e.target)
    const id = kind === 'ws' ? '' : e.target.slice(kind.length + 1)
    lines.push([e.day, e.member_id, name.get(e.member_id), TYPES[kind], id, '', '', e.minutes, (Math.round(e.minutes * 100 / 60) / 100).toFixed(2), e.suggested_minutes, e.note || '', st, '', ''].join(','))
  }
  const ext = format === 'xlsx' ? 'xlsx' : 'csv'
  return {
    bytes: `${lines.join('\r\n')}\r\n`,
    type: ext === 'xlsx' ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'text/csv; charset=utf-8',
    disposition: `attachment; filename="hours-mock-${view.period.start}-${view.period.end}.${ext}"`,
  }
}
