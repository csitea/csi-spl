/**
 * Spec 154 B9: the reader's contact list, the hub routes of section 4 (B3,
 * hub/contacts.go). Loaded only by the lazy contact rows and the card pages:
 * nothing here enters the initial download (C25).
 *
 *   GET    /v1/me/contacts?workspace=&cursor=  a page, {contacts, next}
 *   GET    /v1/me/contacts/{id}                the contact, with its member_id
 *   POST   /v1/me/contacts                     201, the contact
 *   PATCH  /v1/me/contacts/{id}                the contact, member_id null
 *   DELETE /v1/me/contacts/{id}                204
 *   POST   /v1/me/contacts/import[?dry_run=1]  a text/csv body, the counts (B17)
 *
 * The contact is the whole body, no wrapper. A patch keeps a field sent as null
 * and clears one sent as "". tests/unit/contacts-client.test.mjs holds the
 * client and the mock to the hub's answers (testdata/contacts_answers.golden.json).
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
/* the hub's cap, contactsImportMaxBytes: a bigger file is refused before it is sent */
const IMPORT_MAX_BYTES = 5 << 20

function contactsUrl(api, tail, params) {
  const q = new URLSearchParams()
  if (api.tenant) q.set('workspace', String(api.tenant))
  for (const [k, v] of Object.entries(params || {})) q.set(k, String(v))
  const s = q.toString()
  return `${String(api.base || '').replace(/\/+$/, '')}${ROUTE}${tail}${s ? '?' + s : ''}`
}

async function call(api, method, tail, { params, body, csv } = {}) {
  const type = csv ? 'text/csv' : body ? 'application/json' : ''
  const headers = { accept: 'application/json', ...(type ? { 'content-type': type } : {}) }
  let res
  try {
    res = await fetch(contactsUrl(api, tail, params), {
      method,
      credentials: api.credentials,
      headers,
      ...(csv ? { body: csv } : body ? { body: JSON.stringify(body) } : {}),
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

let mockMade = 0

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

/** As the hub: null is not sent, "" clears, and only the list and the card name the member. */
function mockWrite(values, id) {
  const list = mockRead()
  const now = new Date().toISOString()
  const was = id ? mockFound(list, id) : { contact_id: 'mock-' + Date.now().toString(36) + '-' + (++mockMade), first_name: '', last_name: '', email: null, phone: null, google: false, member_id: null, created_at: now, company: '', job_title: '', birthday: null, notes: '', in_only: false, photo: null }
  const next = { ...was, ...Object.fromEntries(Object.entries(values).filter(([, v]) => v !== null)), updated_at: now }
  const row = mockChecked({ ...next, email: next.email || null, phone: next.phone || null })
  mockKeep(id ? list.map((c) => (c.contact_id === id ? row : c)) : [...list, row])
  return { ...row, member_id: null }
}

const MOCK_CSV_COLUMNS = {
  first_name: ['first_name', 'First Name', 'Given Name'],
  last_name: ['last_name', 'Last Name', 'Family Name'],
  email: ['email', 'E-mail 1 - Value'],
  phone: ['phone', 'Phone 1 - Value'],
}
const MOCK_SKIP_CODE = { contact_empty: 'row_empty', bad_email: 'bad_email', bad_phone: 'bad_phone' }
const mockMatchKey = (c) => (c.email ? 'e:' + c.email.toLowerCase() : `n:${c.first_name}|${c.last_name}`)

function mockCsvColumns(names) {
  const at = Object.fromEntries(Object.entries(MOCK_CSV_COLUMNS).map(([f, heads]) => [f, names.findIndex((n) => heads.includes(n))]))
  if (at.email < 0 || at.phone < 0 || (at.first_name < 0 && at.last_name < 0)) throw refused(400, 'csv_unknown_format')
  return at
}

/** The hub's answer for a file of plain cells: quoting is the hub's own test. */
function mockImport(text, dryRun) {
  const [head, ...lines] = text.split(/\r?\n/)
  const names = head.split(',')
  const at = mockCsvColumns(names)
  const there = new Set(mockRead().map(mockMatchKey))
  const fresh = new Map()
  const out = { format: names.includes('first_name') ? 'spool' : 'google', rows: 0, already_there: 0, already_there_by_phone: 0, deleted_here: 0, file_duplicates: 0, skipped: [], photos_ignored: 0 }
  lines.forEach((line, i) => {
    if (!line.trim()) return
    out.rows++
    const cells = line.split(',')
    const row = Object.fromEntries(Object.entries(at).map(([f, n]) => [f, (n < 0 ? '' : cells[n] || '').trim()]))
    const values = { ...row, email: row.email || null, phone: row.phone || null }
    try {
      mockChecked(values)
    } catch (e) {
      out.skipped.push({ line: i + 2, code: MOCK_SKIP_CODE[e.error] })
      return
    }
    const key = mockMatchKey(values)
    if (there.has(key)) out.already_there++
    else if (fresh.has(key)) out.file_duplicates++
    else fresh.set(key, values)
  })
  if (dryRun) return { ...out, would_add: fresh.size }
  for (const values of fresh.values()) mockWrite(values)
  return { ...out, added: fresh.size }
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
  return call(api, 'GET', '/' + encodeURIComponent(id))
}

/** @param {any} api @param {{ first_name: string, last_name: string, email: string | null, phone: string | null }} values */
export async function contactCreate(api, values) {
  const row = api.mock ? mockWrite(values) : await call(api, 'POST', '', { body: values })
  changed()
  return row
}

/** @param {any} api @param {string} id @param {{ first_name: string, last_name: string, email: string | null, phone: string | null }} values */
export async function contactPatch(api, id, values) {
  const body = Object.fromEntries(Object.entries(values).map(([k, v]) => [k, v ?? '']))
  const row = api.mock ? mockWrite(body, id) : await call(api, 'PATCH', '/' + encodeURIComponent(id), { body })
  changed()
  return row
}

/**
 * The card after a patch: the re-read names the member, a patch's answer does
 * not. If the read fails the save stands, and the member the card showed stands
 * with it unless the email changed, which is what the match follows.
 * @param {any} api @param {string} id @param {any} row the patch's answer @param {any} before the card before the edit
 */
export async function contactReread(api, id, row, before) {
  try {
    return await contactGet(api, id)
  } catch {
    return { ...row, member_id: row.email === before?.email ? before?.member_id ?? null : null }
  }
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

/**
 * A CSV file, as its bytes: the hub tells the format and refuses a file that is
 * not UTF-8. `dryRun` answers the counts and writes nothing.
 * @param {any} api @param {File} file @param {{ dryRun?: boolean }} [opts]
 */
export async function contactsImport(api, file, { dryRun = false } = {}) {
  if (file.size > IMPORT_MAX_BYTES) throw refused(413, 'csv_too_large')
  const answer = api.mock
    ? mockImport(await file.text(), dryRun)
    : await call(api, 'POST', '/import', { params: dryRun ? { dry_run: 1 } : {}, csv: file })
  if (!dryRun) changed()
  return answer
}

/** i18n key of a refused file. */
export function contactsImportErrorKey(err) {
  const code = String(err?.error || '')
  return ['csv_too_large', 'csv_unknown_format', 'csv_bad_encoding', 'csv_malformed'].includes(code) ? 'contacts.import.error_' + code : 'contacts.import.failed'
}

/** i18n key of one skipped line's reason. */
export function contactsSkipKey(code) {
  if (code === 'bad_email' || code === 'bad_phone') return 'contacts.error_' + code
  return ['row_empty', 'too_long', 'bad_birthday'].includes(code) ? 'contacts.import.skip_' + code : 'contacts.import.failed'
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
