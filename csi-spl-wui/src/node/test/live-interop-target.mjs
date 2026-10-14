// Target and session for tests/e2e/live-interop.test.mjs (SPL-1782, devops
// guide section 16, gap T5).
//
// Why this exists: the interop test spoke only to an lde hub with the door
// off. dev and prd run the SESSION door (cnf SPOOL_HUB_VIEW_DOOR), so the
// socket upgrade and the view reads need a member session cookie. The owner
// (HUM-10, t1 cd592c84): tests never run in prd by default, but an operator
// can pick one and run it there.
//
// Contract:
//   • no SESSION_COOKIE_FILE and no EMAIL: door off, as before (lde only)
//   • SESSION_COOKIE_FILE: a 0600 file holding the Cookie pair of a test
//     workspace member (`<cookie name>=<value>`, e.g. spool_session_dev=...)
//   • EMAIL + PW_FILE (+ TENANT): signs in with POST /api/v1/auth/login and
//     keeps the spool_session* cookie; the password and the cookie are never
//     printed
//   • either way GET /api/v1/auth/session names the member and the workspace
//     the session writes in; that workspace is checked, not assumed
//   • ENV=prd needs LIVE_INTEROP_PRD_GO=1 and a session, TENANT defaults to
//     e2e and must be e2e or e2e-<x>, and the session's workspace must equal
//     it: t1 and customer workspaces are refused before any socket opens
import { readFileSync, statSync } from 'node:fs'
import { TEST_WORKSPACE_RX } from './run-live-proofs.mjs'

const AUTH = '/api/v1/auth/'

// Returns { env, hub, tenant, door: 'off' | 'session' } or { error }.
export function interopTarget({ ENV, HUB_URL, TENANT, SESSION_COOKIE_FILE, EMAIL, PW_FILE, LIVE_INTEROP_PRD_GO } = {}) {
  const hub = String(HUB_URL || '').replace(/\/+$/, '')
  if (!hub) return { error: 'HUB_URL must be set (no default)' }
  if (!/^https?:\/\/[^/]+/.test(hub)) return { error: `HUB_URL must be http(s): '${HUB_URL}'` }
  if (ENV && ENV !== 'dev' && ENV !== 'prd') return { error: `ENV must be dev or prd when set, got: '${ENV}'` }
  if (EMAIL && !PW_FILE) return { error: 'EMAIL needs PW_FILE (a 0600 file with the password)' }
  if (SESSION_COOKIE_FILE && EMAIL) return { error: 'set SESSION_COOKIE_FILE or EMAIL + PW_FILE, not both' }
  const door = SESSION_COOKIE_FILE || EMAIL ? 'session' : 'off'
  if (ENV !== 'prd') return { env: ENV || '', hub, tenant: TENANT || '', door }
  if (LIVE_INTEROP_PRD_GO !== '1') return { error: 'ENV=prd is opt-in: set LIVE_INTEROP_PRD_GO=1 to run the interop test against prd' }
  if (door !== 'session') return { error: 'ENV=prd needs a test workspace session: SESSION_COOKIE_FILE, or EMAIL + PW_FILE' }
  const tenant = TENANT || 'e2e'
  if (!TEST_WORKSPACE_RX.test(tenant)) return { error: `ENV=prd runs in a test workspace only (e2e or e2e-<x>), got TENANT=${tenant}` }
  return { env: ENV, hub, tenant, door }
}

// A secret file readable by group or others is refused: it is a credential.
export function readSecretFile(path, { stat = statSync, read = readFileSync } = {}) {
  const mode = stat(path).mode & 0o777
  if (mode & 0o077) throw new Error(`${path} is mode ${mode.toString(8)}; a credential file must be 0600`)
  return String(read(path, 'utf8')).trim()
}

// The Cookie pair from a cookie file: `name=value`, one line.
export function cookiePair(text) {
  const v = String(text || '').trim().replace(/^cookie:\s*/i, '')
  if (!/^[A-Za-z0-9_.-]+=[^\s;]+$/.test(v)) throw new Error('the cookie file must hold one `<cookie name>=<value>` pair')
  return v
}

// The spool_session* pair out of a login answer's Set-Cookie lines.
export function sessionFromSetCookie(lines) {
  for (const l of lines || []) {
    const pair = String(l).split(';', 1)[0].trim()
    const eq = pair.indexOf('=')
    if (pair.startsWith('spool_session') && eq > 0 && pair.slice(eq + 1)) return pair
  }
  return ''
}

// Refusal or '' for the workspace a session writes in.
export function sessionTenantRefusal(t, sess) {
  const tenant = (sess && sess.t) || ''
  if (!sess || !sess.hum) return 'the session names no member (signed out, or the cookie expired)'
  if (t.env !== 'prd') return ''
  if (!TEST_WORKSPACE_RX.test(tenant)) return `ENV=prd: the session writes in workspace '${tenant}', not a test workspace (e2e or e2e-<x>)`
  if (tenant !== t.tenant) return `ENV=prd: the session writes in workspace '${tenant}', TENANT is '${t.tenant}'`
  return ''
}

// Returns { cookie, hum, tenant } for a 'session' target; throws on refusal.
export async function openSession(t, env, { fetchFn = globalThis.fetch, readSecret = readSecretFile } = {}) {
  let cookie
  if (env.SESSION_COOKIE_FILE) {
    cookie = cookiePair(readSecret(env.SESSION_COOKIE_FILE))
  } else {
    const body = { email: env.EMAIL, password: readSecret(env.PW_FILE) }
    if (t.tenant) body.tenant = t.tenant
    const res = await fetchFn(`${t.hub}${AUTH}login`, {
      method: 'POST', headers: { accept: 'application/json', 'content-type': 'application/json' }, body: JSON.stringify(body),
    })
    const lines = typeof res.headers.getSetCookie === 'function' ? res.headers.getSetCookie() : [res.headers.get('set-cookie')].filter(Boolean)
    cookie = res.ok ? sessionFromSetCookie(lines) : ''
    if (!cookie) throw new Error(`sign-in refused: POST ${AUTH}login answered ${res.status}`)
  }
  const res = await fetchFn(`${t.hub}${AUTH}session`, { headers: { accept: 'application/json', cookie } })
  const sess = res.ok ? await res.json().catch(() => null) : null
  const why = sessionTenantRefusal(t, sess)
  if (why) throw new Error(res.ok ? why : `GET ${AUTH}session answered ${res.status}: ${why}`)
  return { cookie, hum: sess.hum, tenant: sess.t || '' }
}

// fetch that carries the session cookie (Node sends no browser cookies).
export function cookieFetch(cookie, fetchFn = globalThis.fetch) {
  return (url, init = {}) => fetchFn(url, { ...init, headers: { ...(init.headers || {}), cookie } })
}

// A WebSocket class that sends the session cookie on the upgrade (Node's
// WebSocket takes a headers option; a browser's does not need one).
export function cookieWebSocket(cookie, Base = globalThis.WebSocket) {
  return class extends Base {
    constructor(url, protocols) {
      super(url, protocols ? { protocols, headers: { cookie } } : { headers: { cookie } })
    }
  }
}
