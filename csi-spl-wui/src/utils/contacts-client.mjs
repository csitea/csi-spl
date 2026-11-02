/**
 * Spec 154 B9: the reader's contact list, the hub routes of section 4 (B3,
 * hub/contacts.go). Loaded only by the lazy contact rows and the card pages:
 * nothing here enters the initial download (C25).
 *
 *   GET    /v1/me/contacts?workspace=&cursor=  a page, {contacts, next}
 *   GET    /v1/me/contacts/{id}                {contact}
 *   POST   /v1/me/contacts                     201 {contact}
 *   PATCH  /v1/me/contacts/{id}                {contact}
 *   DELETE /v1/me/contacts/{id}                204
 *
 * Invite is the existing POST /v1/members/invites: the session's workspace
 * and no other (2.4, O4).
 *
 * A refusal throws { status, error } (status 0 off the network). No bearer:
 * the routes are a signed-in person's and answer 403 person_only to one. The
 * mock keeps the list in localStorage (MOCK_CONTACTS_KEY) and counts its reads
 * in globalThis.SPOOL_MOCK_CONTACTS_READS, so an e2e can count the calls.
 */
import { BOOT_READ_TIMEOUT_MS, HUB_WRITE_TIMEOUT_MS } from './fetch-timeouts.mjs'

const MOCK_CONTACTS_KEY = 'spool.mock.contacts'
const ROUTE = '/v1/me/contacts'
/* the hub answers in created_at order and the panel sorts A-Z, so it needs every page */
const MAX_PAGES = 100

function contactsUrl(api, tail, params) {
  const q = new URLSearchParams()
  if (api.tenant) q.set('workspace', String(api.tenant))
  for (const [k, v] of Object.entries(params || {})) q.set(k, String(v))
  const s = q.toString()
  return `${String(api.base || '').replace(/\/+$/, '')}${ROUTE}${tail}${s ? '?' + s : ''}`
}

async function call(api, method, tail, { params, body } = {}) {
  const headers = { accept: 'application/json', ...(body ? { 'content-type': 'application/json' } : {}) }
  let res
  try {
    res = await fetch(contactsUrl(api, tail, params), {
      method,
      credentials: api.credentials,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(method === 'GET' ? BOOT_READ_TIMEOUT_MS : HUB_WRITE_TIMEOUT_MS),
    })
  } catch {
    throw Object.assign(new Error('network'), { status: 0, error: '' })
  }
  const out = res.status === 204 ? null : await res.json().catch(() => null)
  if (!res.ok) throw Object.assign(new Error(`status ${res.status}`), { status: res.status, error: String(out?.error || '') })
  return out
}

const refused = (status, error) => Object.assign(new Error(`status ${status}`), { status, error })

function mockRead() {
  try {
    const list = JSON.parse(globalThis.localStorage?.getItem(MOCK_CONTACTS_KEY) ?? '[]')
    return Array.isArray(list) ? list : []
  } catch {
    return []
  }
}

function mockKeep(list) {
  try {
    globalThis.localStorage?.setItem(MOCK_CONTACTS_KEY, JSON.stringify(list))
  } catch { /* private mode: nothing is kept */ }
}

/** The hub's checks on the four values, its error codes. */
function mockChecked(row) {
  if (!row.first_name && !row.last_name && !row.email && !row.phone) throw refused(400, 'contact_empty')
  if (row.email && !/^[^@\s]+@[^@\s]+$/.test(row.email)) throw refused(400, 'bad_email')
  if (row.phone && !/^\+?[\d\s()./-]{3,}$/.test(row.phone)) throw refused(400, 'bad_phone')
  return row
}

function mockFound(list, id) {
  const hit = list.find((c) => c.contact_id === id)
  if (!hit) throw refused(404, 'not_found')
  return hit
}

function mockWrite(values, id) {
  const list = mockRead()
  const was = id ? mockFound(list, id) : { contact_id: 'mock-' + Date.now().toString(36), google: false, member_id: null }
  const row = mockChecked({ first_name: '', last_name: '', email: null, phone: null, ...was, ...values })
  mockKeep(id ? list.map((c) => (c.contact_id === id ? row : c)) : [...list, row])
  return row
}

async function readEveryPage(api) {
  const out = []
  let cursor = ''
  for (let page = 0; page < MAX_PAGES; page++) {
    const body = await call(api, 'GET', '', { params: cursor ? { cursor } : {} })
    out.push(...(Array.isArray(body?.contacts) ? body.contacts : []))
    cursor = String(body?.next || '')
    if (!cursor) break
  }
  return out
}

/* One read for the panel and the member card: the same list, in this
   workspace, for this person. A write forgets it and tells the panel. */
let held = null
const listeners = new Set()

function changed() {
  held = null
  for (const fn of listeners) fn()
}

/** Call fn after any write of the list; returns the unsubscribe. */
export function onContactsChanged(fn) {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

/**
 * The reader's whole list. `owner` keys the held read (the session's HUM-*),
 * so the next person signing in on this page never sees it.
 * @param {any} api
 * @param {string} owner
 * @returns {Promise<any[]>}
 */
export function contactsList(api, owner) {
  const key = `${api.tenant || ''}|${owner || ''}`
  if (held?.key === key) return held.run
  const run = (async () => {
    if (!api.mock) return readEveryPage(api)
    const g = /** @type {{ SPOOL_MOCK_CONTACTS_READS?: number }} */ (globalThis)
    g.SPOOL_MOCK_CONTACTS_READS = (g.SPOOL_MOCK_CONTACTS_READS || 0) + 1
    return mockRead()
  })()
  held = { key, run }
  run.catch(() => { if (held?.run === run) held = null })
  return run
}

/** One contact, with its member_id in this workspace. */
export async function contactGet(api, id) {
  if (api.mock) return mockFound(mockRead(), id)
  return (await call(api, 'GET', '/' + encodeURIComponent(id)))?.contact
}

/** @param {any} api @param {{ first_name: string, last_name: string, email: string | null, phone: string | null }} values */
export async function contactCreate(api, values) {
  const row = api.mock ? mockWrite(values) : (await call(api, 'POST', '', { body: values }))?.contact
  changed()
  return row
}

/** @param {any} api @param {string} id @param {{ first_name: string, last_name: string, email: string | null, phone: string | null }} values */
export async function contactPatch(api, id, values) {
  const row = api.mock ? mockWrite(values, id) : (await call(api, 'PATCH', '/' + encodeURIComponent(id), { body: values }))?.contact
  changed()
  return row
}

/** Erase one contact. */
export async function contactDelete(api, id) {
  if (api.mock) {
    const list = mockRead()
    mockFound(list, id)
    mockKeep(list.filter((c) => c.contact_id !== id))
  } else await call(api, 'DELETE', '/' + encodeURIComponent(id))
  changed()
}

/** Invite the contact's address to the session's workspace (O4). */
export function contactInvite(api, email, locale) {
  return api.inviteTenantUser({ email, locale })
}

/** i18n key of a refused save. */
export function contactErrorKey(err) {
  const code = String(err?.error || '')
  return ['contact_empty', 'bad_email', 'bad_phone'].includes(code) ? 'contacts.error_' + code : 'contacts.save_failed'
}
