/**
 * Social sign-in client (specs/010-spool-social-auth/contracts/auth-v1.md §1–§4)
 * and native email + password sign-in (specs/015-spool-native-auth/contracts/native-auth-v1.md).
 * Every call goes to the AUTH BASE: the hub's API origin (runtime
 * NUXT_PUBLIC_AUTH_BASE, e.g. https://api.<domain>), cross-origin from the WUI
 * host with credentials, so the hub's session cookie (Domain = the shared
 * parent) rides along and the hub's credentialed CORS admits the WUI origin.
 * '' = same-origin (lde: the nitro devProxy serves /api/v1/auth/**).
 * The WUI never reads the session cookie; it asks GET /api/v1/auth/session.
 *
 * The client itself, the session probe and safeRedirect are the eager
 * auth-client-core.mjs (re-exported here); this file adds the sign-in copy.
 */

import { AUTH_PREFIX, authOrigin, safeRedirect } from './auth-client-core.mjs'

export { AUTH_PREFIX, authOrigin, createAuthClient, safeRedirect, sessionProbeUrl } from './auth-client-core.mjs'

const ERRORS = {
  cancelled: 'Sign-in was cancelled.',
  invalid_state: 'That sign-in link expired — try again.',
  exchange_failed: 'The provider could not confirm you — try again.',
  email_unverified: 'Your account has no verified email with this provider — try another.',
  not_allowed: 'This account has no access here yet — ask your admin for an invite.',
  invite_expired: 'Your invitation has expired — ask your admin to send a new one.',
  // specs/077 T008: the open demo admission refused a 10th live visitor
  demo_full: 'The demo is full right now — try again later.',
  // specs/077 T010: the account's demo visits, or this address's new demo
  // accounts, for today are used
  demo_visits: "You have used today's demo visits — come back tomorrow.",
  demo_signups: 'Too many new demo accounts from this network today — try again tomorrow.',
  unavailable: 'Sign-in is unavailable right now.',
}

/** native-auth-v1 §4 copy, plus the §2 400 details and 5xx fallbacks the forms can meet. */
const NATIVE_ERRORS = {
  invalid_credentials: 'Email or password is wrong.',
  email_unverified: 'Confirm your email first — we can send the link again.',
  not_allowed: 'This account has no access here yet — ask your admin for an invite.',
  invite_expired: 'Your invitation has expired — ask your admin to send a new one.',
  verification_token_invalid: 'That link is not valid any more.',
  verification_token_expired: 'That link expired — we can send a new one.',
  reset_token_invalid: 'That reset link is not valid any more — ask for a new one.',
  email_delivery_unavailable: 'We cannot send email right now — try again later.',
  rate_limited: 'Too many attempts — try again later.',
  unauthenticated: 'Your session ended — sign in again.',
  password_too_short: 'That password is too short.',
  email: 'Enter a valid email address.',
  unavailable: 'Sign-in is unavailable right now.',
  network: 'The hub did not answer — try again.',
}

const NAMES = { google: 'Google', facebook: 'Facebook', microsoft: 'Microsoft', linkedin: 'LinkedIn', xai: 'xAI' }

/** §2 copy; unknown codes get a generic line. Empty code → ''. */
export function authErrorMessage(code) {
  const c = String(code || '')
  if (!c) return ''
  return ERRORS[c] || 'Sign-in failed.'
}

/**
 * native-auth-v1 §1: "Too many attempts — try again in N minutes." for a
 * Retry-After in seconds; unknown / unparsable → the §4 generic line.
 */
export function retryAfterMessage(seconds) {
  const n = Number(seconds)
  if (!Number.isFinite(n) || n <= 0) return NATIVE_ERRORS.rate_limited
  if (n <= 60) return 'Too many attempts — try again in a minute.'
  const m = Math.ceil(n / 60)
  return `Too many attempts — try again in ${m} minutes.`
}

/**
 * Copy for a native call's failure ({ error, detail, retryAfter }). A 400
 * `bad_request` names the field in `detail` (`email`, `password_too_short` + min).
 */
export function nativeErrorMessage(out) {
  const o = out || {}
  const code = String(o.error || '')
  if (!code) return ''
  if (code === 'rate_limited') return retryAfterMessage(o.retryAfter)
  if (code === 'bad_request') {
    const d = String(o.detail || '')
    if (d.startsWith('password_too_short')) {
      const m = /(\d+)/.exec(d)
      return m ? `That password is too short — use at least ${m[1]} characters.` : NATIVE_ERRORS.password_too_short
    }
    if (d.startsWith('email')) return NATIVE_ERRORS.email
    return 'Check the form and try again.'
  }
  return NATIVE_ERRORS[code] || 'Something went wrong — try again.'
}

// ── spec 021: catalogue keys for the copy above ────────────────────────────
// The components render these through t(); the English functions above stay
// the canonical en source and tests/unit/auth-i18n-keys.test.mjs pins every
// i18n/locales/en.json value to them, so the two cannot drift.

/** { key, params } for authErrorMessage(code); null for an empty code. */
export function authErrorKey(code) {
  const c = String(code || '')
  if (!c) return null
  return { key: ERRORS[c] ? `auth.error.${c}` : 'auth.error.failed', params: {} }
}

/** { key, params } for retryAfterMessage(seconds). */
export function retryAfterKey(seconds) {
  const n = Number(seconds)
  if (!Number.isFinite(n) || n <= 0) return { key: 'auth.native_error.rate_limited', params: {} }
  if (n <= 60) return { key: 'auth.native_error.retry_minute', params: {} }
  return { key: 'auth.native_error.retry_minutes', params: { m: Math.ceil(n / 60) } }
}

/** { key, params } for nativeErrorMessage(out); null when there is no error. */
export function nativeErrorKey(out) {
  const o = out || {}
  const code = String(o.error || '')
  if (!code) return null
  if (code === 'rate_limited') return retryAfterKey(o.retryAfter)
  if (code === 'bad_request') {
    const d = String(o.detail || '')
    if (d.startsWith('password_too_short')) {
      const m = /(\d+)/.exec(d)
      return m
        ? { key: 'auth.native_error.password_too_short_min', params: { min: m[1] } }
        : { key: 'auth.native_error.password_too_short', params: {} }
    }
    if (d.startsWith('email')) return { key: 'auth.native_error.email', params: {} }
    return { key: 'auth.native_error.check_form', params: {} }
  }
  return { key: NATIVE_ERRORS[code] ? `auth.native_error.${code}` : 'auth.native_error.generic', params: {} }
}

/** Display name of a provider id: known brands spelled right, else capitalised. */
export function providerName(p) {
  const id = String(p || '')
  return NAMES[id] || (id.charAt(0).toUpperCase() + id.slice(1))
}

export function providerLabel(p) {
  return `Continue with ${providerName(p)}`
}


/**
 * §4: a plain link, no SDK. tenant only when it is a DNS label. The redirect
 * stays a WUI path: the hub lands on <APP_URL><redirect>, APP_URL = the WUI.
 */
export function startHref(provider, redirect, tenant, base = '', hint = '') {
  const q = new URLSearchParams({ redirect: safeRedirect(redirect) })
  const t = String(tenant || '')
  if (/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(t)) q.set('tenant', t)
  // SPL-1231: the invited address pre-selects that account at Google /
  // Microsoft (the hub forwards it only there). Never a credential.
  const h = loginHintOf(hint)
  if (h) q.set('login_hint', h)
  return `${authOrigin(base)}${AUTH_PREFIX}/${encodeURIComponent(String(provider))}/start?${q}`
}

/** SPL-1231: a plain e-mail address (lower-cased) usable as a sign-in hint, '' for anything else. */
export function loginHintOf(v) {
  const s = String(v || '').trim().toLowerCase()
  return s.length >= 3 && s.length <= 320 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s) ? s : ''
}

/**
 * SPL-1231: the sign-in an invited address most likely owns — 'google' for
 * Gmail, 'microsoft' for the Outlook family — or '' when it could be anything
 * (a work address may be Google Workspace, Microsoft 365 or a password).
 */
export function hintedProvider(email) {
  const d = loginHintOf(email).split('@')[1] || ''
  if (d === 'gmail.com' || d === 'googlemail.com') return 'google'
  if (/^(outlook|hotmail|live|msn)\.[a-z.]+$/.test(d)) return 'microsoft'
  return ''
}
