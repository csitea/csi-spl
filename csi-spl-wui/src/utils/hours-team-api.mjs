/**
 * Spec 107 v1.2 T015: the panel's team reads and writes on the hub's T008 /
 * T009 routes (`hours.read`, `hours.approve`): GET /v1/hours, PUT
 * /v1/hours/periods and the GET /v1/hours/export download. Loaded only by
 * the panel's lazy Team / Download chunks. The mock workspace answers from
 * hours-team-mock.mjs.
 */
import { hoursDownloadName, hoursExportPath } from './hours-team.mjs'
import { HUB_WRITE_TIMEOUT_MS } from './fetch-timeouts.mjs'

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

/**
 * GET /v1/hours?period=<day>: the workspace period holding `day`.
 * @param {{ base: string, token?: string, credentials?: RequestCredentials, mock?: boolean }} api
 * @param {string} day YYYY-MM-DD
 * @param {string} today YYYY-MM-DD (the mock's today)
 * @param {AbortSignal} [signal]
 */
export async function loadTeamHours(api, day, today, signal) {
  if (api.mock) {
    const { mockTeamHours } = await import('./hours-team-mock.mjs')
    return mockTeamHours(day, today)
  }
  const r = await fetch(`${rootOf(api)}/v1/hours?period=${encodeURIComponent(day)}`, { credentials: api.credentials, headers: headersOf(api), signal })
  if (!r.ok) throw await refusal(r, 'team hours')
  return r.json()
}

/**
 * PUT /v1/hours/periods with a hoursDecision body; answers the period's team view.
 * @param {any} api as loadTeamHours
 * @param {{ period: string, action: string, members?: string[], note?: string }} body
 * @param {string} today
 */
export async function decideTeamHours(api, body, today) {
  if (api.mock) {
    const { mockDecideHours } = await import('./hours-team-mock.mjs')
    return mockDecideHours(body, today)
  }
  const r = await fetch(`${rootOf(api)}/v1/hours/periods`, {
    method: 'PUT',
    credentials: api.credentials,
    headers: headersOf(api, { 'content-type': 'application/json' }),
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(HUB_WRITE_TIMEOUT_MS),
  })
  if (!r.ok) throw await refusal(r, 'hours decision')
  return r.json()
}

/**
 * GET /v1/hours/export: the file of the period holding `day` as { blob, name }.
 * @param {any} api as loadTeamHours
 * @param {string} day
 * @param {'csv' | 'xlsx'} format
 * @param {boolean} final
 * @param {string} today
 */
export async function downloadTeamHours(api, day, format, final, today) {
  const fallback = `hours-${day}.${format === 'xlsx' ? 'xlsx' : 'csv'}`
  if (api.mock) {
    const { mockExportHours } = await import('./hours-team-mock.mjs')
    const got = mockExportHours(day, format, final, today)
    return { blob: new Blob([got.bytes], { type: got.type }), name: hoursDownloadName(got.disposition, fallback) }
  }
  const r = await fetch(`${rootOf(api)}${hoursExportPath(day, format, final)}`, { credentials: api.credentials, headers: headersOf(api, { accept: '*/*' }), signal: AbortSignal.timeout(HUB_WRITE_TIMEOUT_MS) })
  if (!r.ok) throw await refusal(r, 'hours export')
  return { blob: await r.blob(), name: hoursDownloadName(r.headers.get('content-disposition'), fallback) }
}
