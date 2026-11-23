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
 * Spec 154 B18 (SPL-6278), the Contacts switch in the same section:
 *   GET  /v1/me/contacts/sync?workspace=  {enabled, elsewhere, scope_granted, status_detail, last_synced_at}
 *   PUT  /v1/me/contacts/sync?workspace=  {enabled}: 204; 409 contacts_sync_elsewhere
 *   POST /v1/me/contacts/sync?workspace=  "Sync now", 202; 409 sync_in_progress
 * and connect with ?want=calendar,contacts when the grant lacks the contacts
 * scope. The mock keeps that state in localStorage (MOCK_CONTACTS_SYNC_KEY):
 * 'off' = a workspace outside contacts.workspaces (the hub's 404), else the
 * JSON state the GET would answer.
 *
 * A refusal throws { status, error } (status 0 off the network). The mock
 * workspace keeps the connection in localStorage (MOCK_GCAL_KEY): absent =
 * not connected, 'off' = a workspace outside gcal.workspaces (the hub's 404),
 * else the JSON status the hub would answer.
 */
import { BOOT_READ_TIMEOUT_MS, HUB_WRITE_TIMEOUT_MS } from './fetch-timeouts.mjs'

export const MOCK_GCAL_KEY = 'spool.mock.gcal'
export const MOCK_CONTACTS_SYNC_KEY = 'spool.mock.contacts_sync'
const ROUTE = '/v1/me/google-calendar'
const CONTACTS_SYNC_ROUTE = '/v1/me/contacts/sync'
/* a connect that adds the contacts scope asks the calendar's again: the
   stored grant is the token answer's scope, so it keeps both whatever
   Google answers (spec 154 2.2 step 2) */
export const GCAL_WANT_CONTACTS = 'calendar,contacts'

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

/**
 * SPL-5719: the Calendar page's banner key for a GET answer: the status key
 * of a broken connection ('gcal.status_revoked', 'gcal.status_error'), ''
 * for none (no answer, not connected, connected).
 * @param {any} status the GET body, null on a refusal
 */
export function gcalBannerKey(status) {
  if (gcalView(status, null) !== 'broken') return ''
  return status.status === 'revoked' ? 'gcal.status_revoked' : 'gcal.status_error'
}

/**
 * The notice key for the callback's way back (?gcal=connected,
 * ?gcal_error=<code>), '' for none. An error shows only while it is true
 * (SPL-5726): not before the status is read (view 'loading'), and not once
 * the status reads connected. The browser can request the callback twice
 * (prd 2026-11-16, 0.4 s apart): the first request connects, the second
 * finds its code used (invalid_grant) and sends ?gcal_error=code_expired,
 * the redirect the browser follows last.
 * @param {Record<string, unknown> | null} query the page's route query
 * @param {string} [view] the section's view (gcalView), when known
 */
export function gcalReturnNotice(query, view) {
  if (!query) return ''
  const one = (v) => String((Array.isArray(v) ? v[0] : v) ?? '')
  if (one(query.gcal) === 'connected') return 'gcal.notice_connected'
  if (!one(query.gcal_error)) return ''
  return view === 'loading' || view === 'connected' ? '' : 'gcal.notice_error'
}

/** SPL-5726: re-reads after Sync now, until the last sync moves: how many, how far apart. */
const GCAL_SYNC_REREADS = 6
const GCAL_SYNC_REREAD_MS = 5000

/**
 * SPL-5726: the quiet re-read after Sync now. start(before) reads the status
 * every `ms`, up to `reads` times, until its last_synced_at is not `before`;
 * a new start() or stop() ends the run before it. A read already in flight
 * when that happens is dropped when it lands: it neither reports nor reads
 * again (the review's W1: a page left mid-read kept reading for 25 s).
 * @param {() => Promise<any>} read the status GET
 * @param {(status: any) => void} onStatus called with each read of a live run
 * @param {{ reads?: number, ms?: number, setT?: typeof setTimeout, clearT?: typeof clearTimeout }} [opts]
 */
export function gcalSyncFollower(read, onStatus, opts = {}) {
  const reads = opts.reads ?? GCAL_SYNC_REREADS
  const ms = opts.ms ?? GCAL_SYNC_REREAD_MS
  const setT = opts.setT ?? setTimeout
  const clearT = opts.clearT ?? clearTimeout
  let gen = 0
  let timer = null
  const stop = () => {
    gen++
    if (timer) clearT(timer)
    timer = null
  }
  const next = (run, before, left) => {
    timer = null
    if (left <= 0) return
    timer = setT(async () => {
      timer = null
      let st
      try { st = await read() } catch { st = undefined }
      if (run !== gen) return
      if (st !== undefined) onStatus(st)
      if (st === undefined || st?.last_synced_at === before) next(run, before, left - 1)
    }, ms)
  }
  return {
    start(before) { stop(); next(gen, before, reads) },
    stop,
  }
}

/** The hub URL of a route: ?workspace=<the page's workspace> first, then params. */
export function gcalUrl(api, tail, params, route = ROUTE) {
  const q = new URLSearchParams()
  if (api.tenant) q.set('workspace', String(api.tenant))
  for (const [k, v] of Object.entries(params || {})) q.set(k, String(v))
  const s = q.toString()
  return `${String(api.base || '').replace(/\/+$/, '')}${route}${tail}${s ? '?' + s : ''}`
}

async function call(api, method, tail, { params, timeoutMs, route = ROUTE, body } = {}) {
  const headers = { accept: 'application/json', ...(body ? { 'content-type': 'application/json' } : {}) }
  /* the contacts routes are a signed-in person's: a bearer is refused (person_only) */
  if (api.token && route === ROUTE) headers.authorization = `Bearer ${api.token}`
  let res
  try {
    res = await fetch(gcalUrl(api, tail, params, route), {
      method,
      credentials: api.credentials,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
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
  return call(api, 'GET', '', { timeoutMs: BOOT_READ_TIMEOUT_MS })
}

/**
 * POST connect: the URL of Google's consent page; want (GCAL_WANT_CONTACTS)
 * asks the contacts scope too. The mock has no Google: it stores a connected
 * row at once (and the contacts grant, for want) and answers no URL (the
 * section re-reads).
 */
export async function gcalConnect(api, want) {
  if (api.mock) {
    mockStatus()
    if (want && String(want).includes('contacts')) {
      const cs = mockContactsSync()
      mockContactsKeep({ ...cs, scope_granted: true })
      if (mockRead()) return ''
    }
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
  const out = await call(api, 'POST', '/connect', { params: want ? { want } : null, timeoutMs: HUB_WRITE_TIMEOUT_MS })
  return String(out?.authorize_url || '')
}

/** POST sync: a cycle is due now. */
export async function gcalSync(api) {
  if (api.mock) {
    const s = mockStatus()
    if (s.connected) mockKeep({ ...s, last_synced_at: new Date().toISOString() })
    return
  }
  await call(api, 'POST', '/sync', { timeoutMs: HUB_WRITE_TIMEOUT_MS })
}

/** DELETE: revoke at Google and forget the connection; removeImported also trashes the imported events. */
export async function gcalDisconnect(api, removeImported) {
  if (api.mock) {
    mockStatus()
    mockKeep(null)
    return
  }
  await call(api, 'DELETE', '', { params: { remove_imported: removeImported ? 1 : 0 }, timeoutMs: HUB_WRITE_TIMEOUT_MS })
}

/* ---- spec 154 B18: the Contacts switch ---- */

const CONTACTS_SYNC_NONE = { enabled: false, elsewhere: false, scope_granted: false, status_detail: '', last_synced_at: null }

function mockContactsRaw() {
  try {
    return globalThis.localStorage?.getItem(MOCK_CONTACTS_SYNC_KEY) ?? null
  } catch {
    return null
  }
}

function mockContactsSync() {
  const raw = mockContactsRaw()
  if (raw === 'off') throw Object.assign(new Error('status 404'), { status: 404, error: 'not_found' })
  if (!raw) return { ...CONTACTS_SYNC_NONE }
  try {
    return { ...CONTACTS_SYNC_NONE, ...JSON.parse(raw) }
  } catch {
    return { ...CONTACTS_SYNC_NONE }
  }
}

function mockContactsKeep(v) {
  try {
    globalThis.localStorage?.setItem(MOCK_CONTACTS_SYNC_KEY, JSON.stringify(v))
  } catch { /* private mode: nothing is kept */ }
}

/**
 * What the Contacts switch shows (spec 154 2.7, B18): 'hidden' (the
 * workspace is outside contacts.workspaces, 404, or no answer yet),
 * 'failed', 'elsewhere' (the person's binding is in another workspace),
 * 'off', 'grant' (on, but the Google grant lacks the contacts scope: the
 * sync waits until it is given) or 'on'.
 * @param {any} state the GET body, null on a refusal or before it
 * @param {{ status?: number } | null} [err]
 */
export function contactsSyncView(state, err) {
  if (err) return err.status === 404 || err.status === 403 ? 'hidden' : 'failed'
  if (!state) return 'hidden'
  if (state.elsewhere) return 'elsewhere'
  if (!state.enabled) return 'off'
  return state.scope_granted ? 'on' : 'grant'
}

/** GET: the Contacts switch's state in this workspace. */
export async function contactsSyncState(api) {
  if (api.mock) return mockContactsSync()
  const out = await call(api, 'GET', '', { timeoutMs: BOOT_READ_TIMEOUT_MS, route: CONTACTS_SYNC_ROUTE })
  return { ...CONTACTS_SYNC_NONE, ...(out || {}) }
}

/** PUT: the switch on or off. A refusal throws { status, error } (409 contacts_sync_elsewhere). */
export async function contactsSyncSet(api, enabled) {
  if (api.mock) {
    const cs = mockContactsSync()
    if (cs.elsewhere && enabled) throw Object.assign(new Error('status 409'), { status: 409, error: 'contacts_sync_elsewhere' })
    mockContactsKeep({ ...cs, enabled: !!enabled })
    return
  }
  await call(api, 'PUT', '', { timeoutMs: HUB_WRITE_TIMEOUT_MS, route: CONTACTS_SYNC_ROUTE, body: { enabled: !!enabled } })
}

/** POST: "Sync now" for contacts, 202; 409 sync_in_progress. */
export async function contactsSyncNow(api) {
  if (api.mock) {
    const cs = mockContactsSync()
    if (!cs.enabled) throw Object.assign(new Error('status 409'), { status: 409, error: 'gcal_not_connected' })
    if (cs.scope_granted) mockContactsKeep({ ...cs, last_synced_at: new Date().toISOString() })
    return
  }
  await call(api, 'POST', '', { timeoutMs: HUB_WRITE_TIMEOUT_MS, route: CONTACTS_SYNC_ROUTE })
}
