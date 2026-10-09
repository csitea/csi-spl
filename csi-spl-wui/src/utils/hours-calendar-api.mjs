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

/**
 * Spec 107 T013 / T014: PUT /v1/me/hours {entries?, remove?, resubmit?} - the
 * member's approve, edit, reject, add, note and resubmit (T006). Answers the
 * period of the first day named, as GET reads it after the writes. Throws
 * { status, error, detail } on a refusal (409 period_frozen, 400 day_cap),
 * { status: 0 } off the network.
 * @param {{ base: string, token?: string, credentials?: RequestCredentials, mock?: boolean }} api
 * @param {{ entries?: any[], remove?: any[], resubmit?: string }} body
 * @param {string} today YYYY-MM-DD (the mock's today)
 */
export async function putMyHours(api, body, today) {
  if (api.mock) {
    const { mockPutMyHours } = await import('./hours-calendar-mock.mjs')
    return mockPutMyHours(body, today)
  }
  const headers = { accept: 'application/json', 'content-type': 'application/json' }
  if (api.token) headers.authorization = `Bearer ${api.token}`
  let res
  try {
    res = await fetch(`${String(api.base).replace(/\/+$/, '')}/v1/me/hours`, {
      method: 'PUT',
      credentials: api.credentials,
      headers,
      body: JSON.stringify(body),
    })
  } catch {
    throw Object.assign(new Error('network'), { status: 0 })
  }
  const out = await res.json().catch(() => null)
  if (!res.ok) {
    throw Object.assign(new Error(`status ${res.status}`), { status: res.status, error: String(out?.error || ''), detail: String(out?.detail || out?.message || '') })
  }
  return out
}
