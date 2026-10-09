// P3-02 (perf audit round 3): a signed-out visitor goes to /login before any
// JS loads.
//
// A signed-out visit to a product screen loaded `/`, booted the app, probed
// the session (401) and only then hard-navigated to the prerendered /login:
// 301 / 919 ms (desktop / phone, n=10, dev) and 1.29 / 1.75 s on fast 4G, two
// documents and two session probes. The session cookie is HttpOnly, so the
// document cannot see it; the WUI keeps its own hint instead
// (utils/signed-out-hint.mjs): `spl_so=1` once the session read 'out', gone
// once it reads 'in' or a sign-in starts. This inline <head> script reads it:
// the hint on a product screen -> location.replace(<login>?redirect=<here>).
//
// The hint only ever says what this browser last saw, so:
//   - no hint (a new browser, a signed-in reader, a hint cleared on sign-in)
//     -> today's path: the app probes and the middleware decides.
//   - a stale hint (signed in somewhere the WUI did not see) -> /login, whose
//     own probe reads 'in' and continues to the page (pages/login.vue reads
//     EARLY_LOGIN_FLAG), and the store drops the hint.
//
// Plain ES5 on purpose, like rootLocaleRedirect.mjs: the decision is
// serialised with toString() and inlined; its sha256 goes into the Hosting
// CSP with every other inline block. Unit-tested by
// tests/unit/signed-out-redirect-script.test.mjs, which also pins the product
// screens to utils/signed-out-redirect.mjs isProductScreen.
import { SIGNED_OUT_HINT_COOKIE, EARLY_LOGIN_FLAG } from './signed-out-hint.mjs'

/**
 * The login address for a signed-out visitor of this document, or '' to stay.
 *
 * @param {object} input
 * @param {string} input.path       location.pathname
 * @param {string} input.search     location.search
 * @param {string} input.hash       location.hash
 * @param {string} input.cookie     document.cookie
 * @param {string} input.cookieKey  the hint cookie's name
 * @param {string[]} input.locales  shipped locale codes (route prefixes)
 * @param {string} input.defaultLocale the unprefixed locale
 * @returns {string}
 */
export function earlyLoginHref(input) {
  var key = String(input.cookieKey || '')
  var parts = String(input.cookie || '').split(';')
  var hint = false
  for (var c = 0; c < parts.length; c++) {
    var kv = parts[c]
    var eq = kv.indexOf('=')
    if (eq < 0) continue
    if (kv.slice(0, eq).replace(/^\s+|\s+$/g, '') === key && kv.slice(eq + 1).replace(/^\s+|\s+$/g, '') === '1') hint = true
  }
  if (!key || !hint) return ''
  var path = String(input.path || '/')
  var full = path + String(input.search || '') + String(input.hash || '')
  // the same refusals as safeRedirect: a path the login page could not send back
  if (full.charAt(0) !== '/' || full.charAt(1) === '/' || /[\s\u0000-\u001f\u007f\\]/.test(full)) return ''
  var p = path
  if (p.length > 1 && p.charAt(p.length - 1) === '/') p = p.slice(0, -1)
  var seg = p.split('/')
  var prefix = ''
  var locales = input.locales || []
  if (seg.length >= 2 && locales.indexOf(seg[1].toLowerCase()) >= 0) {
    if (seg[1].toLowerCase() !== input.defaultLocale) prefix = '/' + seg[1]
    p = '/' + seg.slice(2).join('/')
    if (p.length > 1 && p.charAt(p.length - 1) === '/') p = p.slice(0, -1)
  }
  var product = p === '/' || p === '/lobby' || p === '/search'
  // no /docs: the docs page is its own door (a public doc reads signed out)
  var roots = ['/channel', '/dm', '/t', '/settings']
  for (var r = 0; r < roots.length; r++) {
    if (p === roots[r] || p.indexOf(roots[r] + '/') === 0) product = true
  }
  if (!product) return ''
  return prefix + '/login?redirect=' + encodeURIComponent(full)
}

/**
 * The inline script for nuxt.config `app.head.script`; place it before the
 * early session probe (that one stays home when this one leaves).
 *
 * @param {{ locales: string[], defaultLocale: string }} opts
 * @returns {string} JavaScript source
 */
export function buildSignedOutRedirectScript(opts) {
  return [
    '(function(){try{',
    'if(window.__spoolLeaving)return;',
    'var h=(' + earlyLoginHref.toString() + ')({',
    'path:location.pathname,search:location.search,hash:location.hash,cookie:document.cookie,',
    'cookieKey:' + JSON.stringify(SIGNED_OUT_HINT_COOKIE) + ',',
    'locales:' + JSON.stringify(opts.locales) + ',defaultLocale:' + JSON.stringify(opts.defaultLocale) + '});',
    'if(!h)return;',
    'window.__spoolLeaving=1;',
    'try{sessionStorage.setItem(' + JSON.stringify(EARLY_LOGIN_FLAG) + ',"1")}catch(e){}',
    'location.replace(h);',
    '}catch(e){}})();',
  ].join('')
}
