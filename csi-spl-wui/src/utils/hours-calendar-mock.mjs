/**
 * Spec 107 v1.2 T011: the mock workspace's GET /v1/me/hours?period=day
 * (lde and e2e; never in a hub build's path). A weekly period, Monday
 * first, in the T006 shape: per day its rows (approved entries and open
 * suggestions), the open count and the period's state. Days after `today`
 * and weekends hold nothing, so a weekend shows no line and a weekday
 * always does.
 *
 * T013 / T014: the mock's PUT /v1/me/hours keeps the member's writes in
 * localStorage (HOURS_MOCK_ENTRIES), and the answers read them back as the
 * hub does: an entry with its delta when the suggestion grew since, a
 * removed entry gives back its suggestion, 400 day_cap above 1440 approved
 * minutes a day, 409 period_frozen on a frozen or Final period. A period's
 * state (returned with a note, frozen, approved) is set in
 * HOURS_MOCK_PERIODS by an e2e; Resubmit moves returned to frozen.
 */
import { hoursAddDays } from './hours-calendar.mjs'

export const HOURS_MOCK_TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
export const HOURS_MOCK_TOPIC_2 = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
/** the member's writes: { "<day>|<target>": entry | { removed: true } } */
export const HOURS_MOCK_ENTRIES = 'spool.mock.hours-entries'
/** period states by start day: { "<YYYY-MM-DD>": { state, note } } */
export const HOURS_MOCK_PERIODS = 'spool.mock.hours-periods'

const CAP = 1440

/* where the mock keeps its writes: localStorage in a browser, else memory (unit) */
const memory = new Map()
function readJSON(key) {
  try {
    if (typeof localStorage !== 'undefined') return JSON.parse(localStorage.getItem(key) || '{}') || {}
  } catch { /* fall back */ }
  return memory.get(key) || {}
}
function writeJSON(key, v) {
  try {
    if (typeof localStorage !== 'undefined') { localStorage.setItem(key, JSON.stringify(v)); return }
  } catch { /* fall back */ }
  memory.set(key, v)
}
/** forget every write (unit tests) */
export function mockHoursReset() {
  memory.clear()
  try { if (typeof localStorage !== 'undefined') { localStorage.removeItem(HOURS_MOCK_ENTRIES); localStorage.removeItem(HOURS_MOCK_PERIODS) } } catch { /* none */ }
}
/** set a period's state, e.g. returned with a note (e2e, unit) */
export function mockHoursSetPeriod(start, state, note = '') {
  const ps = readJSON(HOURS_MOCK_PERIODS)
  ps[start] = { state, note }
  writeJSON(HOURS_MOCK_PERIODS, ps)
}

function monday(iso) {
  const wd = new Date(`${iso}T00:00:00Z`).getUTCDay()
  return hoursAddDays(iso, -((wd + 6) % 7))
}

function block(day, from, to) {
  return { start: `${day}T${from}:00Z`, end: `${day}T${to}:00Z` }
}

/**
 * The fixture of a weekday, by its weekday number (1 = Monday): per target
 * the current suggestion (`sug`) and a stored entry, if any. Tuesday's topic
 * entry was approved at 0:50 and its suggestion is now 1:10: a delta of 0:20.
 */
function fixtureOf(day, wd) {
  const sug = (target, minutes, blocks) => ({ target, sug: minutes, entry: null, blocks })
  const ok = (target, minutes, blocks, now = minutes) => ({ target, sug: now, entry: { state: 'approved', minutes, suggested_minutes: minutes, note: '' }, blocks })
  if (wd === 1) {
    return [
      sug(`t:${HOURS_MOCK_TOPIC}`, 110, [block(day, '09:00', '10:50')]),
      ok('cal:mock-weekly-sync', 60, [block(day, '11:00', '12:00')]),
      sug('ws', 15, []),
    ]
  }
  if (wd === 2) {
    return [
      ok(`t:${HOURS_MOCK_TOPIC}`, 50, [block(day, '09:10', '10:20')], 70),
      sug('ch:lobby', 25, [block(day, '13:00', '13:25')]),
    ]
  }
  return [sug(`t:${HOURS_MOCK_TOPIC_2}`, 40, [block(day, '10:00', '10:40')])]
}

/** the fixture of `date` for a member whose today is `today` */
function fixtureFor(date, today) {
  const wd = (new Date(`${date}T00:00:00Z`).getUTCDay() + 6) % 7 + 1
  return wd <= 5 && date <= today ? fixtureOf(date, wd) : []
}

/** the rows of one day as the hub answers them (hours_me.go dayJSON) */
function rowsFor(date, today, stored, locked) {
  const out = []
  const seen = new Set()
  for (const f of fixtureFor(date, today)) {
    seen.add(f.target)
    const w = stored[`${date}|${f.target}`]
    const entry = w ? (w.removed ? null : w) : f.entry
    if (entry) {
      const row = { target: f.target, state: entry.state, minutes: entry.minutes, suggested_minutes: entry.suggested_minutes, blocks: f.blocks }
      if (entry.note) row.note = entry.note
      if (!locked && f.sug > entry.suggested_minutes) row.delta = f.sug - entry.suggested_minutes
      out.push(row)
    } else if (!locked) {
      out.push({ target: f.target, state: 'suggested', minutes: f.sug, suggested_minutes: f.sug, blocks: f.blocks })
    }
  }
  for (const [k, w] of Object.entries(stored)) {
    const [d, target] = [k.slice(0, 10), k.slice(11)]
    if (d !== date || seen.has(target) || w.removed) continue
    const row = { target, state: w.state, minutes: w.minutes, suggested_minutes: w.suggested_minutes, blocks: [] }
    if (w.note) row.note = w.note
    out.push(row)
  }
  return out.sort((a, b) => b.minutes - a.minutes || (a.target < b.target ? -1 : 1))
}

/**
 * The period holding `day` for a member whose today is `today`.
 * @param {string} day YYYY-MM-DD
 * @param {string} today YYYY-MM-DD
 */
export function mockMyHours(day, today) {
  const start = monday(day)
  const end = hoursAddDays(start, 6)
  const stored = readJSON(HOURS_MOCK_ENTRIES)
  const pstate = readJSON(HOURS_MOCK_PERIODS)[start] || { state: 'open', note: '' }
  const locked = pstate.state === 'frozen' || pstate.state === 'approved'
  const days = []
  for (let i = 0; i < 7; i++) {
    const date = hoursAddDays(start, i)
    const rows = rowsFor(date, today, stored, locked || pstate.state === 'returned')
    days.push({
      date,
      today: date === today,
      closed: date < today,
      frozen: locked,
      suggested_minutes: rows.filter((r) => r.state === 'suggested').reduce((n, r) => n + r.minutes, 0),
      approved_minutes: rows.filter((r) => r.state === 'approved').reduce((n, r) => n + r.minutes, 0),
      open: rows.filter((r) => r.state === 'suggested' || r.delta > 0).length,
      rows,
    })
  }
  const period = { start, end, state: pstate.state, minutes: 0, freezes_at: `${hoursAddDays(end, 3)}T00:00:00Z` }
  if (pstate.note) period.note = pstate.note
  return { tz: 'UTC', today, period, days }
}

function refuse(status, error, detail) {
  return Object.assign(new Error(`status ${status}`), { status, error, detail })
}

/**
 * PUT /v1/me/hours {entries?, remove?, resubmit?} on the mock: all or
 * nothing, then the period of the first day named, as GET reads it.
 * @param {{ entries?: any[], remove?: { day: string, target: string }[], resubmit?: string }} body
 * @param {string} today YYYY-MM-DD
 */
export function mockPutMyHours(body, today) {
  const entries = Array.isArray(body?.entries) ? body.entries : []
  const remove = Array.isArray(body?.remove) ? body.remove : []
  const named = [...entries.map((e) => e.day), ...remove.map((k) => k.day), ...(body?.resubmit ? [body.resubmit] : [])]
  if (!named.length) throw refuse(400, 'bad_hours', 'nothing to write')
  const periods = readJSON(HOURS_MOCK_PERIODS)
  for (const d of named) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(String(d)) || d > today) throw refuse(400, 'bad_day', 'a day after today has no hours yet')
    const st = (periods[monday(d)] || {}).state
    if (st === 'frozen' || st === 'approved') throw refuse(409, 'period_frozen', "the day's hours period is frozen")
  }
  if (body.resubmit && (periods[monday(body.resubmit)] || {}).state !== 'returned') {
    throw refuse(409, 'period_state', 'the period cannot be resubmitted in its state')
  }
  const next = { ...readJSON(HOURS_MOCK_ENTRIES) }
  for (const e of entries) {
    if (!['approved', 'rejected'].includes(e.state) || !(e.minutes >= 0 && e.minutes <= CAP) || [...String(e.note || '')].length > 500) {
      throw refuse(400, 'bad_hours', 'bad hours row')
    }
    const f = fixtureFor(e.day, today).find((x) => x.target === e.target)
    const old = next[`${e.day}|${e.target}`]
    const suggested = f ? f.sug : old && !old.removed ? old.suggested_minutes : 0
    next[`${e.day}|${e.target}`] = { state: e.state, minutes: e.minutes, suggested_minutes: suggested, note: String(e.note || '').trim() }
  }
  for (const k of remove) next[`${k.day}|${k.target}`] = { removed: true }
  /* the day cap counts approved entries, the fixture's included (memHoursCap) */
  for (const d of new Set(entries.map((e) => e.day))) {
    let sum = 0
    for (const f of fixtureFor(d, today)) {
      const w = next[`${d}|${f.target}`]
      const entry = w ? (w.removed ? null : w) : f.entry
      if (entry && entry.state === 'approved') sum += entry.minutes
    }
    for (const [k, w] of Object.entries(next)) {
      if (k.startsWith(`${d}|`) && !w.removed && w.state === 'approved' && !fixtureFor(d, today).some((f) => k === `${d}|${f.target}`)) sum += w.minutes
    }
    if (sum > CAP) throw refuse(400, 'day_cap', 'a day holds at most 1440 minutes')
  }
  writeJSON(HOURS_MOCK_ENTRIES, next)
  if (body.resubmit) {
    periods[monday(body.resubmit)] = { state: 'frozen', note: '' }
    writeJSON(HOURS_MOCK_PERIODS, periods)
  }
  return mockMyHours(named[0], today)
}
