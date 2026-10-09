/**
 * Spec 107 v1.2 T011: the mock workspace's GET /v1/me/hours?period=day
 * (lde and e2e; never in a hub build's path). A weekly period, Monday
 * first, in the T006 shape: per day its rows (approved entries and open
 * suggestions), the open count and the period's state. Days after `today`
 * and weekends hold nothing, so a weekend shows no line and a weekday
 * always does.
 */
import { hoursAddDays } from './hours-calendar.mjs'

export const HOURS_MOCK_TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
export const HOURS_MOCK_TOPIC_2 = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'

function monday(iso) {
  const wd = new Date(`${iso}T00:00:00Z`).getUTCDay()
  return hoursAddDays(iso, -((wd + 6) % 7))
}

function block(day, from, to) {
  return { start: `${day}T${from}:00Z`, end: `${day}T${to}:00Z` }
}

/** the fixture rows of a weekday, by its weekday number (1 = Monday) */
function rowsOf(day, wd) {
  const sug = (target, minutes, blocks) => ({ target, state: 'suggested', minutes, suggested_minutes: minutes, blocks })
  const ok = (target, minutes, blocks) => ({ target, state: 'approved', minutes, suggested_minutes: minutes, blocks })
  if (wd === 1) {
    return [
      sug(`t:${HOURS_MOCK_TOPIC}`, 110, [block(day, '09:00', '10:50')]),
      ok('cal:mock-weekly-sync', 60, [block(day, '11:00', '12:00')]),
      sug('ws', 15, []),
    ]
  }
  if (wd === 2) {
    return [
      ok(`t:${HOURS_MOCK_TOPIC}`, 50, [block(day, '09:10', '10:00')]),
      sug('ch:lobby', 25, [block(day, '13:00', '13:25')]),
    ]
  }
  return [sug(`t:${HOURS_MOCK_TOPIC_2}`, 40, [block(day, '10:00', '10:40')])]
}

/**
 * The period holding `day` for a member whose today is `today`.
 * @param {string} day YYYY-MM-DD
 * @param {string} today YYYY-MM-DD
 */
export function mockMyHours(day, today) {
  const start = monday(day)
  const end = hoursAddDays(start, 6)
  const days = []
  for (let i = 0; i < 7; i++) {
    const date = hoursAddDays(start, i)
    const wd = i + 1
    const rows = wd <= 5 && date <= today ? rowsOf(date, wd) : []
    days.push({
      date,
      today: date === today,
      closed: date < today,
      frozen: false,
      suggested_minutes: rows.filter((r) => r.state === 'suggested').reduce((n, r) => n + r.minutes, 0),
      approved_minutes: rows.filter((r) => r.state === 'approved').reduce((n, r) => n + r.minutes, 0),
      open: rows.filter((r) => r.state === 'suggested').length,
      rows,
    })
  }
  return {
    tz: 'UTC',
    today,
    period: { start, end, state: 'open', minutes: 0, freezes_at: `${hoursAddDays(end, 3)}T00:00:00Z` },
    days,
  }
}
