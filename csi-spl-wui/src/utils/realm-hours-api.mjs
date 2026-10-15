/**
 * Spec 118 T005 (sections 5.2, 7): the person's hours across workspaces on
 * the hub's realm routes (T003, T004):
 *   GET /v1/me/realm/hours?from=&to=&tz=   the personal days (hours.Across)
 *   PUT /v1/me/realm/hours                 rows into several workspaces
 *   GET /v1/me/realm/targets?workspace=&q= one workspace's targets
 * A realm route takes the person from the session alone: it refuses a
 * request naming a workspace (X-Spool-Tenant), so none is sent. The mock
 * answers an empty window. The `api` is useSpoolApi()'s { base, token,
 * credentials, mock }, as hours-team-api.mjs takes it.
 */
import { HUB_READ_TIMEOUT_MS, HUB_WRITE_TIMEOUT_MS } from './fetch-timeouts.mjs'

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

/**
 * @typedef {Object} RealmRow one PUT row: minutes, or start and end
 * @property {string} workspace
 * @property {string} op_id the retry key
 * @property {string} day YYYY-MM-DD in the workspace's zone
 * @property {string} target
 * @property {number} [minutes]
 * @property {string} [start] RFC 3339
 * @property {string} [end] RFC 3339
 * @property {string} [note]
 * @property {string} [state]
 */

/** @typedef {{ rows: Array<{ op_id: string, workspace: string, status: 'ok' | 'period_frozen' | 'day_over_1440' | 'overlap_in_workspace' | 'unknown_target' | 'not_a_member' | 'bad_row' | 'unavailable', detail?: string, replayed?: boolean }> }} RealmWrite */
/** @typedef {{ workspace: string, targets: Array<{ target: string, label: string, kind: string }> }} RealmTargets */
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

/**
 * PUT /v1/me/realm/hours: 200 with a status per row; no atomicity across
 * workspaces (one workspace's refusal leaves the others saved).
 * @param {RealmApi} api
 * @param {RealmRow[]} rows
 * @returns {Promise<RealmWrite>}
 */
export async function saveRealmHours(api, rows) {
  if (api.mock) return { rows: rows.map((row) => ({ op_id: row.op_id, workspace: row.workspace, status: 'ok' })) }
  const r = await fetch(`${rootOf(api)}/v1/me/realm/hours`, {
    method: 'PUT',
    credentials: api.credentials,
    headers: headersOf(api, { 'content-type': 'application/json' }),
    body: JSON.stringify(rows),
    signal: AbortSignal.timeout(HUB_WRITE_TIMEOUT_MS),
  })
  if (!r.ok) throw await refusal(r, 'realm hours save')
  return r.json()
}

/**
 * GET /v1/me/realm/targets: what `workspace` shows the person to enter on.
 * @param {RealmApi} api
 * @param {string} workspace
 * @param {string} [q]
 * @param {AbortSignal} [signal]
 * @returns {Promise<RealmTargets>}
 */
export async function loadRealmTargets(api, workspace, q = '', signal) {
  if (api.mock) return { workspace, targets: [] }
  const r = await fetch(`${rootOf(api)}/v1/me/realm/targets${query({ workspace, q })}`, {
    credentials: api.credentials, headers: headersOf(api), signal: signal || AbortSignal.timeout(HUB_READ_TIMEOUT_MS),
  })
  if (!r.ok) throw await refusal(r, 'realm targets')
  return r.json()
}
