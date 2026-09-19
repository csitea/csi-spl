/**
 * Social sign-in client (specs/010-spool-social-auth/contracts/auth-v1.md §1–§4).
 * Same-origin: Hosting rewrites /api/v1/auth/** to the hub (lde: nitro devProxy).
 * The WUI never reads the spool_session cookie; it asks GET /api/v1/auth/session.
 */

export const AUTH_PREFIX = '/api/v1/auth'

const ERRORS = {
  cancelled: 'Sign-in was cancelled.',
  invalid_state: 'That sign-in link expired — try again.',
  exchange_failed: 'The provider could not confirm you — try again.',
  email_unverified: 'Your account has no verified email with this provider — try another.',
  not_allowed: 'This account cannot sign in here.',
  unavailable: 'Sign-in is unavailable right now.',
}

const NAMES = { google: 'Google', facebook: 'Facebook', microsoft: 'Microsoft', linkedin: 'LinkedIn', xai: 'xAI' }

/** §2 copy; unknown codes get a generic line. Empty code → ''. */
export function authErrorMessage(code) {
  const c = String(code || '')
  if (!c) return ''
  return ERRORS[c] || 'Sign-in failed.'
}

export function providerLabel(p) {
  const id = String(p || '')
  return `Continue with ${NAMES[id] || (id.charAt(0).toUpperCase() + id.slice(1))}`
}

/** A same-site path to land on after sign-in; anything else → '/' (the hub enforces the same). */
export function safeRedirect(path) {
  const p = String(path || '')
  if (!p.startsWith('/') || p.startsWith('//') || p.startsWith('/\\')) return '/'
  if (p.startsWith('/login')) return '/'
  return p
}

/** §4: a plain link, no SDK. tenant only when it is a DNS label. */
export function startHref(provider, redirect, tenant) {
  const q = new URLSearchParams({ redirect: safeRedirect(redirect) })
  const t = String(tenant || '')
  if (/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(t)) q.set('tenant', t)
  return `${AUTH_PREFIX}/${encodeURIComponent(String(provider))}/start?${q}`
}

export function createAuthClient({ fetchFn = globalThis.fetch, base = '' } = {}) {
  const root = String(base || '').replace(/\/+$/, '')
  const call = (path, opts) => fetchFn(`${root}${AUTH_PREFIX}${path}`, {
    credentials: 'same-origin',
    ...opts,
    headers: { accept: 'application/json', ...(opts && opts.headers) },
  })

  return {
    /** Enabled providers in cnf order; [] = auth off (or unreachable → also []). */
    async providers() {
      try {
        const res = await call('/providers')
        if (!res.ok) return []
        const data = await res.json()
        return Array.isArray(data && data.providers) ? data.providers.map(String) : []
      } catch {
        return []
      }
    },
    /**
     * §4 signed-in probe: 200 → 'in', 401 → 'out', anything else (5xx, network,
     * bad JSON) → 'unknown' — keep state, never treat as signed out.
     */
    async session() {
      let res
      try {
        res = await call('/session', { cache: 'no-store' })
      } catch {
        return { state: 'unknown', claims: null }
      }
      if (res.status === 401) return { state: 'out', claims: null }
      if (res.status !== 200) return { state: 'unknown', claims: null }
      try {
        return { state: 'in', claims: await res.json() }
      } catch {
        return { state: 'unknown', claims: null }
      }
    },
    async logout() {
      const res = await call('/logout', { method: 'POST' })
      return res.status === 204 || res.ok
    },
  }
}
