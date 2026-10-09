/**
 * Spec 107 v1.2 T011: the calendar's read of the member's hours, every
 * GET /v1/me/hours?period= answer covering [first, last] (T006). Loaded only
 * by the calendar's lazy chunks. The mock workspace answers from
 * hours-calendar-mock.mjs.
 */
import { hoursCollectPeriods } from './hours-calendar.mjs'

/**
 * @param {{ base: string, token?: string, credentials?: RequestCredentials, mock?: boolean }} api
 * @param {string} first YYYY-MM-DD
 * @param {string} last YYYY-MM-DD
 * @param {string} today YYYY-MM-DD (the mock's today)
 * @param {AbortSignal} [signal]
 */
export async function loadHoursRange(api, first, last, today, signal) {
  if (api.mock) {
    const { mockMyHours } = await import('./hours-calendar-mock.mjs')
    return hoursCollectPeriods(first, last, async (day) => mockMyHours(day, today))
  }
  const headers = { accept: 'application/json' }
  if (api.token) headers.authorization = `Bearer ${api.token}`
  const base = String(api.base).replace(/\/+$/, '')
  return hoursCollectPeriods(first, last, async (day) => {
    const r = await fetch(`${base}/v1/me/hours?period=${encodeURIComponent(day)}`, { credentials: api.credentials, headers, signal })
    if (!r.ok) throw Object.assign(new Error(`hours ${r.status}`), { status: r.status })
    return r.json()
  })
}
