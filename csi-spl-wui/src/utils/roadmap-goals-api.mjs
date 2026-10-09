/**
 * Spec 112 WUI-3: where a workspace's goal events come from.
 *
 * - Signed in: GET /v1/calendar/events?source_key=goal: (HUB-1). The hub
 *   reads the SESSION's workspace (humanTenant), so only that workspace is
 *   read; another membership is shown after the tenant switch.
 * - Signed out: GET /v1/public/calendar/events of the page host's workspace
 *   (rdb 0158), a public roadmap's events; an internal roadmap answers none.
 *   Only events with a `goal:` key count.
 * The mock workspace answers from roadmap-goals-mock.mjs. Throws on a
 * refusal, carrying the HTTP `status`.
 */
import { DOC_READ_TIMEOUT_MS } from './fetch-timeouts.mjs'
import { isoSeconds } from './iso-seconds.mjs'
import { PUBLIC_CALENDAR_WEB_PATH } from './public-calendar-web.mjs'

const DAY = 86400000
/* the hub's widest range read is 400 days (calendarMaxRangeDays) */
const PAST_DAYS = 120
const AHEAD_DAYS = 279

const goalOnly = (events) => (Array.isArray(events) ? events : []).filter((e) => e && typeof e.source_key === 'string' && e.source_key.startsWith('goal:'))

/**
 * The goal events of the session's workspace (`ws`).
 * @param {{ base?: string, mock?: boolean, token?: string, credentials?: RequestCredentials }} api
 * @param {string} ws
 * @param {string[]} memberOf the viewer's workspaces (the mock checks it)
 */
export async function fetchMemberGoalEvents(api, ws, memberOf) {
  if (api.mock) {
    const { mockGoalEvents } = await import('./roadmap-goals-mock.mjs')
    return goalOnly(mockGoalEvents(ws, memberOf).events)
  }
  const headers = { accept: 'application/json' }
  if (api.token) headers.authorization = `Bearer ${api.token}`
  const q = new URLSearchParams({ source_key: 'goal:' })
  const r = await fetch(`${String(api.base || '')}/v1/calendar/events?${q}`, { credentials: api.credentials, headers, signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
  if (!r.ok) throw Object.assign(new Error(`goal events ${r.status}`), { status: r.status })
  return goalOnly((await r.json())?.events)
}

/**
 * The page host's public goal events, read without a session.
 * @param {{ base?: string, mock?: boolean }} api
 * @param {string} host
 * @param {number} [nowMs]
 */
export async function fetchPublicGoalEvents(api, host, nowMs = Date.now()) {
  if (api.mock) {
    const { mockPublicGoalEvents } = await import('./roadmap-goals-mock.mjs')
    return goalOnly(mockPublicGoalEvents(host).events)
  }
  const q = new URLSearchParams({ start: isoSeconds(new Date(nowMs - PAST_DAYS * DAY)), end: isoSeconds(new Date(nowMs + AHEAD_DAYS * DAY)) })
  const r = await fetch(`${String(api.base || '')}${PUBLIC_CALENDAR_WEB_PATH}?${q}`, {
    credentials: 'omit', headers: { accept: 'application/json' }, signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS),
  })
  if (!r.ok) throw Object.assign(new Error(`public calendar ${r.status}`), { status: r.status })
  return goalOnly((await r.json())?.events)
}
