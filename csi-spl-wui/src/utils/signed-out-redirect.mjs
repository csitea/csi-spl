/**
 * Signed-out product screens go to /login. Only a settled 'out' qualifies
 * (isSignedOutVisitor): 'loading' is a probe in flight and 'unknown' is an
 * unreachable hub, so a redirect there would trap someone whose cookie is
 * still good. The mock tenant has no sign-in. Login, reset, verify and
 * checkout stay put so the redirect cannot loop.
 */
import { safeRedirect } from './auth-client.mjs'
import { isSignedOutVisitor } from './shell-bootstrap.mjs'

/** Shipped UI locales (nuxt.config I18N_LOCALES). `dm` is a route, not one of these. */
export const SIGNED_OUT_LOCALE_CODES = Object.freeze([
  'bg', 'fi', 'ru', 'en', 'sv', 'he', 'tr', 'mk', 'el',
  'lt', 'et', 'lv', 'sr', 'ro', 'uk', 'sk', 'pl', 'es', 'nl',
])

const LOCALE_CODES = new Set(SIGNED_OUT_LOCALE_CODES)

/**
 * Pathname with the locale prefix removed, no query or hash, no trailing slash.
 * @param {string} input
 * @returns {string}
 */
export function productPath(input) {
  const raw = String(input || '')
  let path = raw.split('#')[0].split('?')[0] || '/'
  if (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1)
  if (!path.startsWith('/')) path = `/${path}`
  const parts = path.split('/')
  if (parts.length >= 2 && LOCALE_CODES.has(parts[1].toLowerCase())) {
    const rest = parts.slice(2).join('/')
    path = rest ? `/${rest}` : '/'
    if (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1)
  }
  return path || '/'
}

const EXEMPT = [
  /^\/login(?:\/|$)/,
  /^\/reset-password(?:\/|$)/,
  /^\/verify-email(?:\/|$)/,
  /^\/checkout(?:\/|$)/,
]

/** @param {string} input */
export function isExemptScreen(input) {
  const p = productPath(input)
  return EXEMPT.some((re) => re.test(p))
}

/** Product screens that replace themselves with /login once the session is 'out'. */
export function isProductScreen(input) {
  const p = productPath(input)
  if (isExemptScreen(p)) return false
  if (p === '/' || p === '/lobby' || p === '/search') return true
  if (p === '/channel' || p.startsWith('/channel/')) return true
  if (p === '/dm' || p.startsWith('/dm/')) return true
  if (p === '/t' || p.startsWith('/t/')) return true
  if (p === '/settings' || p.startsWith('/settings/')) return true
  return false
}

/**
 * Login location for a settled signed-out visitor on a product screen.
 * Null means stay: not signed out, or this path must not redirect.
 * `redirect` is the path they asked for, passed through safeRedirect.
 * @param {string} fullPath
 * @param {unknown} sessionState
 * @param {boolean} [mock]
 * @returns {{ path: '/login', query: { redirect: string } } | null}
 */
export function signedOutLoginTarget(fullPath, sessionState, mock = false) {
  if (!isSignedOutVisitor(sessionState, mock)) return null
  if (!isProductScreen(fullPath)) return null
  return { path: '/login', query: { redirect: safeRedirect(String(fullPath || '/')) } }
}

/**
 * Address of the prerendered login document. `loginPath` is the locale-aware
 * path (`/login`, `/fi/login`). The redirect query is encoded once.
 * @param {string} loginPath
 * @param {string} redirect
 * @returns {string}
 */
export function signedOutLoginHref(loginPath, redirect) {
  const path = String(loginPath || '/login')
  const value = String(redirect || '')
  if (!value) return path
  const hashAt = path.indexOf('#')
  const hash = hashAt >= 0 ? path.slice(hashAt) : ''
  const before = hashAt >= 0 ? path.slice(0, hashAt) : path
  const joiner = before.includes('?') ? '&' : '?'
  return `${before}${joiner}${new URLSearchParams({ redirect: value }).toString()}${hash}`
}
