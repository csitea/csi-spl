/**
 * Spec 149 B8 (SPL-3227): the member's own Google Calendar connection, the
 * hub routes of section 4 (B5, hub/gcal_connect.go). Loaded only by the
 * Settings -> Google Calendar section (components/settings/calendar-google.vue),
 * its own chunk: nothing here enters the initial download (C27).
 *
 *   GET    /v1/me/google-calendar?workspace=          the connection, never a token
 *   POST   /v1/me/google-calendar/connect?workspace=  {authorize_url}
 *   POST   /v1/me/google-calendar/sync?workspace=     202; 409 sync_in_progress
 *   DELETE /v1/me/google-calendar?workspace=&remove_imported=0|1   204
 *
 * A refusal throws { status, error } (status 0 off the network). The mock
 * workspace keeps the connection in localStorage (MOCK_GCAL_KEY): absent =
 * not connected, 'off' = a workspace outside gcal.workspaces (the hub's 404),
 * else the JSON status the hub would answer.
 */
import { BOOT_READ_TIMEOUT_MS, HUB_WRITE_TIMEOUT_MS } from './fetch-timeouts.mjs'

export const MOCK_GCAL_KEY = 'spool.mock.gcal'
const ROUTE = '/v1/me/google-calendar'

/**
 * What the section shows for a GET answer or its refusal (sections 2.7, 2.9):
 * 'off' (404: the workspace is not on gcal.workspaces), 'not_configured'
 * (503), 'failed' (anything else), 'disconnected', 'connected', or 'broken'
 * (status revoked or error: its reason and Reconnect).
 * @param {any} status the GET body, null on a refusal
 * @param {{ status?: number } | null} [err]
 */
export function gcalView(status, err) {
  if (err) {
    if (err.status === 404) return 'off'
    if (err.status === 503) return 'not_configured'
    return 'failed'
  }
  if (!status || !status.connected) return 'disconnected'
  return status.status === 'revoked' || status.status === 'error' ? 'broken' : 'connected'
}

/** The notice key for the callback's way back (?gcal=connected, ?gcal_error=<code>), '' for none. */
export function gcalReturnNotice(query) {
  if (!query) return ''
  const one = (v) => String((Array.isArray(v) ? v[0] : v) ?? '')
  if (one(query.gcal) === 'connected') return 'gcal.notice_connected'
  if (one(query.gcal_error)) return 'gcal.notice_error'
  return ''
}

/** The hub URL of a route: ?workspace=<the page's workspace> first, then params. */
export function gcalUrl(api, tail, params) {
  const q = new URLSearchParams()
  if (api.tenant) q.set('workspace', String(api.tenant))
  for (const [k, v] of Object.entries(params || {})) q.set(k, String(v))
  const s = q.toString()
  return `${String(api.base || '').replace(/\/+$/, '')}${ROUTE}${tail}${s ? '?' + s : ''}`
}

async function call(api, method, tail, params, timeoutMs) {
  const headers = { accept: 'application/json' }
  if (api.token) headers.authorization = `Bearer ${api.token}`
  let res
  try {
    res = await fetch(gcalUrl(api, tail, params), {
      method,
      credentials: api.credentials,
      headers,
      signal: AbortSignal.timeout(timeoutMs),
    })
  } catch {
    throw Object.assign(new Error('network'), { status: 0, error: '' })
  }
  const out = res.status === 204 ? null : await res.json().catch(() => null)
  if (!res.ok) throw Object.assign(new Error(`status ${res.status}`), { status: res.status, error: String(out?.error || '') })
  return out
}

function mockRead() {
  try {
    return globalThis.localStorage?.getItem(MOCK_GCAL_KEY) ?? null
  } catch {
    return null
  }
}

function mockKeep(v) {
  try {
    if (v === null) globalThis.localStorage?.removeItem(MOCK_GCAL_KEY)
    else globalThis.localStorage?.setItem(MOCK_GCAL_KEY, JSON.stringify(v))
  } catch { /* private mode: nothing is kept */ }
}

function mockStatus() {
  const raw = mockRead()
  if (raw === 'off') throw Object.assign(new Error('status 404'), { status: 404, error: 'not_found' })
  if (!raw) return { connected: false }
  try {
    return JSON.parse(raw)
  } catch {
    return { connected: false }
  }
}

/** GET: the member's connection in this workspace. */
export async function gcalStatus(api) {
  if (api.mock) return mockStatus()
  return call(api, 'GET', '', null, BOOT_READ_TIMEOUT_MS)
}

/**
 * POST connect: the URL of Google's consent page. The mock has no Google: it
 * stores a connected row at once and answers no URL (the section re-reads).
 */
export async function gcalConnect(api) {
  if (api.mock) {
    mockStatus()
    mockKeep({
      connected: true,
      google_email: 'member@example.com',
      calendar_title: 'Spool Hub (Mock)',
      status: 'connected',
      status_detail: '',
      last_synced_at: new Date().toISOString(),
    })
    return ''
  }
  const out = await call(api, 'POST', '/connect', null, HUB_WRITE_TIMEOUT_MS)
  return String(out?.authorize_url || '')
}

/** POST sync: a cycle is due now. */
export async function gcalSync(api) {
  if (api.mock) {
    const s = mockStatus()
    if (s.connected) mockKeep({ ...s, last_synced_at: new Date().toISOString() })
    return
  }
  await call(api, 'POST', '/sync', null, HUB_WRITE_TIMEOUT_MS)
}

/** DELETE: revoke at Google and forget the connection; removeImported also trashes the imported events. */
export async function gcalDisconnect(api, removeImported) {
  if (api.mock) {
    mockStatus()
    mockKeep(null)
    return
  }
  await call(api, 'DELETE', '', { remove_imported: removeImported ? 1 : 0 }, HUB_WRITE_TIMEOUT_MS)
}
