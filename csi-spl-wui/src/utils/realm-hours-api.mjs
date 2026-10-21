/**
 * Spec 118 T005 (sections 5.2, 7): the person's hours across workspaces on
 * the hub's realm route (T003):
 *   GET /v1/me/realm/hours?from=&to=&tz=   the personal days (hours.Across)
 * The PUT /v1/me/realm/hours and GET /v1/me/realm/targets clients had no
 * caller and were removed (r15-09); add them back with their first user.
 * A realm route takes the person from the session alone: it refuses a
 * request naming a workspace (X-Spool-Tenant), so none is sent. The mock
 * answers an empty window. The `api` is useSpoolApi()'s { base, token,
 * credentials, mock }, as hours-team-api.mjs takes it.
 */
import { HUB_READ_TIMEOUT_MS } from './fetch-timeouts.mjs'

/** @typedef {import('./hours-across').PersonalDay} PersonalDay */
/** @typedef {import('./hours-across').Totals} Totals */

/**
 * @typedef {Object} RealmHours the GET answer
 * @property {string} tz the person's zone (IANA)
 * @property {'profile' | 'browser' | 'default'} tz_source
 * @property {string} from YYYY-MM-DD
 * @property {string} to YYYY-MM-DD
 * @property {Array<{ id: string, name: string, state: string }>} workspaces state: member, left or unavailable
 * @property {PersonalDay[]} days
 * @property {Totals} totals
 * @property {boolean} incomplete
 * @property {Array<{ valid_from: string, day_minutes: number | null, week_minutes: number | null }>} limits
 */

/** @typedef {{ base: string, token?: string, credentials?: RequestCredentials, mock?: boolean }} RealmApi */

function headersOf(api, extra = {}) {
  const h = { accept: 'application/json', ...extra }
  if (api.token) h.authorization = `Bearer ${api.token}`
  return h
}

function rootOf(api) {
  return String(api.base).replace(/\/+$/, '')
}

/** A refusal as an Error with the hub's `status` and `error` token. */
async function refusal(r, what) {
  let token = ''
  try { token = String((await r.json())?.error || '') } catch { /* not json */ }
  return Object.assign(new Error(`${what} ${r.status}`), { status: r.status, token })
}

/** The query string of the defined, non-empty params. */
function query(params) {
  const q = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) if (v) q.set(k, String(v))
  const s = q.toString()
  return s ? `?${s}` : ''
}

/**
 * GET /v1/me/realm/hours: the window from..to (at most 62 days; both empty =
 * the person's current week). `tz` is the browser's zone, used when the realm
 * profile has none.
 * @param {RealmApi} api
 * @param {{ from?: string, to?: string, tz?: string }} window
 * @param {AbortSignal} [signal]
 * @returns {Promise<RealmHours>}
 */
export async function loadRealmHours(api, { from = '', to = '', tz = '' } = {}, signal) {
  if (api.mock) {
    return { tz: tz || 'UTC', tz_source: tz ? 'browser' : 'default', from, to, workspaces: [], days: [], totals: { reported: 0, open: 0, actual: 0, overlap: 0, unplaced: 0, data_error_minutes: 0 }, incomplete: false, limits: [] }
  }
  const r = await fetch(`${rootOf(api)}/v1/me/realm/hours${query({ from, to, tz })}`, {
    credentials: api.credentials, headers: headersOf(api), signal: signal || AbortSignal.timeout(HUB_READ_TIMEOUT_MS),
  })
  if (!r.ok) throw await refusal(r, 'realm hours')
  return r.json()
}

