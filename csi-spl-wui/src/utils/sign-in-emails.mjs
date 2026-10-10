/**
 * A member's sign-in emails (owner HUM-10, t1 f265541a; hub 153e6c359):
 * Settings -> Sign-in and security -> Sign-in emails, and the same list on a
 * member in Workspace settings -> Members. The panel is
 * components/SignInEmailsPanel.vue, loaded only with those views; the mock
 * workspace answers from sign-in-emails-mock.mjs.
 *
 *   GET    /v1/members/{human_id}/emails          { human_id, emails: [{ email, state, providers, main }] }
 *   POST   /v1/members/{human_id}/emails {email}  { human_id, email, state, reason }
 *   DELETE /v1/members/{human_id}/emails?email=   204; 409 last_sign_in | main_email
 *
 * An added address stays PENDING until its holder signs in with it at an
 * identity provider while signed in here: the browser goes to the provider's
 * auth start with link=1 from its own session (the hub refuses it without
 * one), so only the holder can confirm, never an admin.
 */
import { startHref } from './auth-client.mjs'
import { HUB_WRITE_TIMEOUT_MS } from './fetch-timeouts.mjs'

/** The identity providers a pending address can be confirmed with, in button order. */
export const SIGN_IN_EMAIL_PROVIDERS = ['google', 'facebook', 'linkedin', 'microsoft']

const PROVIDER_NAME = { google: 'Google', facebook: 'Facebook', linkedin: 'LinkedIn', microsoft: 'Microsoft' }

/** A provider slug as its brand name; '' for password (the catalogue words that one). */
export function signInEmailProviderName(p) {
  const k = String(p || '').trim().toLowerCase()
  if (k === 'password' || !k) return ''
  return PROVIDER_NAME[k] || k.charAt(0).toUpperCase() + k.slice(1)
}

/** One list item of the hub, defaulted: state is 'active' or 'pending'; anything unknown reads pending. */
export function normalizeSignInEmail(r) {
  const o = r && typeof r === 'object' ? r : {}
  const email = typeof o.email === 'string' ? o.email.trim().toLowerCase() : ''
  const providers = Array.isArray(o.providers)
    ? [...new Set(o.providers.filter((p) => typeof p === 'string' && p).map((p) => p.toLowerCase()))]
    : []
  return {
    email,
    state: o.state === 'active' ? 'active' : 'pending',
    providers,
    main: o.main === true,
  }
}

/** The list answer -> rows: the main address first, then active, then pending, each by address. */
export function signInEmailRows(body) {
  const list = body && Array.isArray(body.emails) ? body.emails : []
  const rank = (r) => (r.main ? 0 : r.state === 'active' ? 1 : 2)
  return list.map(normalizeSignInEmail).filter((r) => r.email)
    .sort((a, b) => rank(a) - rank(b) || a.email.localeCompare(b.email))
}

/**
 * The providers a pending row offers as "Confirm with ..." buttons: those the
 * hub enables (GET /providers) that can prove an address, in button order.
 */
export function signInEmailConfirmProviders(enabled) {
  const on = new Set((Array.isArray(enabled) ? enabled : []).map((p) => String(p).toLowerCase()))
  return SIGN_IN_EMAIL_PROVIDERS.filter((p) => on.has(p))
}

/**
 * The link sign-in that proves a pending address: the provider's start with
 * link=1, the address as the login hint (Google and Microsoft pre-select
 * it), and the WUI path to land on afterwards.
 */
export function signInEmailConfirmHref(provider, email, redirect, tenant = '', base = '') {
  return `${startHref(provider, redirect, tenant, base, email)}&link=1`
}

/** A plain address the hub would take, lower-cased; '' otherwise. */
export function signInEmailAddress(v) {
  const s = String(v || '').trim().toLowerCase()
  return s.length >= 3 && s.length <= 320 && /^[^\s@,;<>()"]+@[^\s@,;<>()"]+\.[^\s@,;<>()"]+$/.test(s) ? s : ''
}

/** The add answer as a catalogue key: pending until a provider sign-in (the owner's words), or already active. */
export function signInEmailAddedKey(answer) {
  const a = answer && typeof answer === 'object' ? answer : {}
  if (a.reason === 'already_active' || a.state === 'active') return 'signin_emails.added_active'
  return 'signin_emails.added_pending'
}

const ERROR_KEYS = {
  email_taken: 'signin_emails.error_taken',
  last_sign_in: 'signin_emails.error_last_sign_in',
  main_email: 'signin_emails.error_main_email',
  bad_email: 'signin_emails.error_bad_email',
  act_as: 'signin_emails.error_act_as',
  not_found: 'signin_emails.error_not_found',
}

/** A refusal (an Error with status + token) as a catalogue key. */
export function signInEmailErrorKey(err) {
  const token = err && typeof err.token === 'string' ? err.token : ''
  if (Object.prototype.hasOwnProperty.call(ERROR_KEYS, token)) return ERROR_KEYS[token]
  if (err && err.status === 403) return 'signin_emails.error_forbidden'
  return 'signin_emails.error_failed'
}

// ── the hub calls ──────────────────────────────────────────────────────────

function headersOf(api, extra = {}) {
  const h = { accept: 'application/json', ...extra }
  if (api.token) h.authorization = `Bearer ${api.token}`
  return h
}

function emailsUrl(api, humanId) {
  return `${String(api.base).replace(/\/+$/, '')}/v1/members/${encodeURIComponent(String(humanId || ''))}/emails`
}

/** A refusal as an Error with the hub's `status` and `error` token. */
async function refusal(r, what) {
  let token = ''
  try { token = String((await r.json())?.error || '') } catch { /* not json */ }
  return Object.assign(new Error(`sign-in emails ${what} ${r.status}`), { status: r.status, token })
}

async function mockStore() {
  return (await import('./sign-in-emails-mock.mjs')).signInEmailsMock()
}

/**
 * GET: the member's addresses.
 * @param {{ base: string, token?: string, credentials?: RequestCredentials, mock?: boolean }} api the spool client
 * @param {string} humanId
 */
export async function loadSignInEmails(api, humanId) {
  if (api.mock) return (await mockStore()).list(humanId)
  const r = await fetch(emailsUrl(api, humanId), { credentials: api.credentials, headers: headersOf(api), cache: 'no-store' })
  if (!r.ok) throw await refusal(r, 'list')
  return r.json()
}

/** POST: add an address as pending; answers { human_id, email, state, reason }. */
export async function addSignInEmail(api, humanId, email) {
  if (api.mock) return (await mockStore()).add(humanId, email)
  const r = await fetch(emailsUrl(api, humanId), {
    method: 'POST',
    credentials: api.credentials,
    headers: headersOf(api, { 'content-type': 'application/json' }),
    body: JSON.stringify({ email }),
    signal: AbortSignal.timeout(HUB_WRITE_TIMEOUT_MS),
  })
  if (!r.ok) throw await refusal(r, 'add')
  return r.json()
}

/** DELETE: remove a pending or extra address (204). */
export async function removeSignInEmail(api, humanId, email) {
  if (api.mock) return (await mockStore()).remove(humanId, email)
  const r = await fetch(`${emailsUrl(api, humanId)}?email=${encodeURIComponent(email)}`, {
    method: 'DELETE',
    credentials: api.credentials,
    headers: headersOf(api),
    signal: AbortSignal.timeout(HUB_WRITE_TIMEOUT_MS),
  })
  if (!r.ok) throw await refusal(r, 'remove')
  return null
}

/** The providers the mock workspace enables (live, the auth client's GET /providers says). */
export async function mockSignInEmailProviders() {
  return (await mockStore()).providers()
}
