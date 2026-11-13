/**
 * Spec 107 FR-41 (SPL-5440, section 22): the workspace's average hours per
 * day, a soft norm. The hub keeps it as the registered key
 * hours.norm_day_minutes (0..1440 minutes, 0 = none); a holder of
 * hours.norm (biz_owner, product_owner, admin) reads and sets it through
 * GET / PUT /v1/hours/norm, and every member reads it on GET /v1/me/hours
 * (`norm_day_minutes`). It refuses nothing: a day above it shows a warning.
 *
 * Pure rules plus the two calls; loaded only by the lazy Hours settings
 * section and the calendar's lazy chunks, never the initial chunk. The mock
 * workspace keeps its value in localStorage (HOURS_MOCK_NORM). Node tests
 * import this file.
 */
import { HUB_READ_TIMEOUT_MS, HUB_WRITE_TIMEOUT_MS } from './fetch-timeouts.mjs'

export const HOURS_KEY_NORM = 'hours.norm_day_minutes'
export const HOURS_NORM_PERM = 'hours.norm'
/** the largest norm, a whole day (the hub's day cap) */
export const HOURS_NORM_MAX = 1440

const HOURS_MOCK_NORM = 'spool.mock.hours-norm'
let mockMemory = 0

/** A norm in minutes from an answer's field; junk or out of range = 0 (none). */
export function hoursNormOf(v) {
  const n = Number(v)
  return Number.isInteger(n) && n > 0 && n <= HOURS_NORM_MAX ? n : 0
}

/**
 * Minutes from what a person types: "7:30", "7.5", "7,5" or "7" (hours).
 * '' is 0 (no norm). NaN when it is not a time of 0..24 h in whole minutes.
 * @param {unknown} text
 */
export function hoursNormParse(text) {
  const s = String(text ?? '').trim()
  if (s === '') return 0
  let m = /^(\d{1,2}):([0-5]\d)$/.exec(s)
  let min = Number.NaN
  if (m) min = Number(m[1]) * 60 + Number(m[2])
  else if ((m = /^(\d{1,2})(?:[.,](\d{1,2}))?$/.exec(s))) min = Math.round(Number(`${m[1]}.${m[2] || '0'}`) * 60)
  return Number.isInteger(min) && min >= 0 && min <= HOURS_NORM_MAX ? min : Number.NaN
}

/** How many minutes `total` is above `norm`; 0 when no norm or not above. */
export function hoursOverNorm(total, norm) {
  const n = hoursNormOf(norm)
  const t = Math.max(0, Math.round(Number(total) || 0))
  return n > 0 && t > n ? t - n : 0
}

/** the mock workspace's norm (lde, e2e, unit) */
export function mockHoursNorm() {
  try {
    if (typeof localStorage !== 'undefined') return hoursNormOf(localStorage.getItem(HOURS_MOCK_NORM))
  } catch { /* fall back */ }
  return mockMemory
}

/** set the mock workspace's norm; 400 bad_setting outside 0..1440 */
export function mockSetHoursNorm(n) {
  if (!Number.isInteger(n) || n < 0 || n > HOURS_NORM_MAX) {
    throw Object.assign(new Error('status 400'), { status: 400, error: 'bad_setting', token: 'bad_setting', detail: '' })
  }
  try {
    if (typeof localStorage !== 'undefined') { localStorage.setItem(HOURS_MOCK_NORM, String(n)); return }
  } catch { /* fall back */ }
  mockMemory = n
}

function headersOf(api, write) {
  const h = { accept: 'application/json' }
  if (write) h['content-type'] = 'application/json'
  if (api.token) h.authorization = `Bearer ${api.token}`
  return h
}

/**
 * GET or PUT /v1/hours/norm. Answers { norm_day_minutes, max_minutes };
 * throws { status, error, token, detail } on a refusal, { status: 0 } off the network.
 * @param {{ base: string, token?: string, credentials?: RequestCredentials, mock?: boolean }} api
 * @param {number} [minutes] set it (PUT); omitted = read (GET)
 */
export async function hoursNormCall(api, minutes) {
  const write = minutes !== undefined
  if (api.mock) {
    if (write) mockSetHoursNorm(minutes)
    return { norm_day_minutes: mockHoursNorm(), max_minutes: HOURS_NORM_MAX }
  }
  let res
  try {
    res = await fetch(`${String(api.base).replace(/\/+$/, '')}/v1/hours/norm`, {
      method: write ? 'PUT' : 'GET',
      credentials: api.credentials,
      headers: headersOf(api, write),
      body: write ? JSON.stringify({ norm_day_minutes: minutes }) : undefined,
      signal: AbortSignal.timeout(write ? HUB_WRITE_TIMEOUT_MS : HUB_READ_TIMEOUT_MS),
    })
  } catch {
    throw Object.assign(new Error('network'), { status: 0 })
  }
  const out = await res.json().catch(() => null)
  if (!res.ok) {
    // `token` is what tenantSettingsErrorKey reads (forbidden, bad_setting)
    const token = String(out?.error || '')
    throw Object.assign(new Error(`status ${res.status}`), { status: res.status, error: token, token, detail: String(out?.detail || '') })
  }
  return out
}
