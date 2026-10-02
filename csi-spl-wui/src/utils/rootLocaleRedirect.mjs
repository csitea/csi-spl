// spec 021 (copied from the donor WUI) — locale resolution for the
// unprefixed root `/`.
//
// The WUI is prerendered (`nuxt generate`) and served by Firebase Hosting, so
// `/` can only ever ship ONE locale's markup: the default one
// (`prefix_except_default`). Nothing runs server-side per request, which is
// why the locale a visitor ends up in has to be decided BEFORE Vue hydrates
// — otherwise the client's first render disagrees with the shipped markup
// ("Hydration completed but contains mismatches").
//
// `resolveRootLocale` is the single decision: cookie → Accept-Language
// (navigator.languages is the browser's Accept-Language list) → default.
// `buildRootLocaleRedirectScript` inlines that same function into a blocking
// <head> script so the decision runs before any body markup is parsed: a
// non-default locale triggers `location.replace('/<code>')` to the
// prerendered page for that locale (a real navigation, so there is no flash
// of the default locale and nothing to hydrate); the default locale falls
// through to the markup that is already in hand.
//
// Plain ES5 on purpose: the function body is serialised with `toString()`
// and shipped verbatim to every browser, so no spread/arrow/const.
// Unit-tested by tests/unit/root-locale-redirect.test.mjs.

/**
 * Crawlers are exempt: `/` stays the default-locale home and hreflang
 * alternates (useLocaleHead) already point them at the other 18 locales.
 * Without this, a renderer with an en-US `navigator.languages` (Googlebot)
 * would see `/` as a redirect to `/en/` and the bg home would drop out.
 */
export const CRAWLER_UA_RE = /bot|crawl|spider|slurp|bingpreview|lighthouse|pagespeed|headlesschrome\/[0-9.]+ *\(?google/i

/**
 * Decide the locale a visitor of `/` should land in.
 *
 * @param {object} input
 * @param {string} input.cookie        raw `document.cookie` / Cookie header
 * @param {string} input.cookieKey     locale cookie name (i18n_redirected)
 * @param {string[]} input.languages   navigator.languages / Accept-Language tags
 * @param {string[]} input.supported   locale codes the site ships
 * @param {string} input.defaultLocale fallback code
 * @returns {string} a code from `supported` (never empty)
 */
export function resolveRootLocale(input) {
  var supported = input.supported || []
  var cookie = String(input.cookie || '')
  var key = String(input.cookieKey || '')
  if (key) {
    var parts = cookie.split(';')
    for (var p = 0; p < parts.length; p++) {
      var kv = parts[p]
      var eq = kv.indexOf('=')
      if (eq < 0) continue
      if (kv.slice(0, eq).replace(/^\s+|\s+$/g, '') !== key) continue
      var val = kv.slice(eq + 1).replace(/^\s+|\s+$/g, '')
      try { val = decodeURIComponent(val) } catch (e) { /* keep raw */ }
      if (supported.indexOf(val) >= 0) return val
    }
  }
  var langs = input.languages || []
  for (var i = 0; i < langs.length; i++) {
    // "ru-RU;q=0.8" → "ru"; "zh-Hant-TW" → "zh"
    var code = String(langs[i] || '').split(';')[0].replace(/^\s+|\s+$/g, '').toLowerCase().split('-')[0]
    if (code && supported.indexOf(code) >= 0) return code
  }
  return input.defaultLocale
}

/**
 * Build the inline, blocking <head> script for nuxt.config `app.head.script`.
 * Runs only on the exact root path, never for crawlers, and redirects only
 * when the resolved locale is not the default (which is what `/` already is).
 *
 * @param {{ supported: string[], defaultLocale: string, cookieKey: string }} opts
 * @returns {string} JavaScript source
 */
export function buildRootLocaleRedirectScript(opts) {
  var supported = JSON.stringify(opts.supported)
  var def = JSON.stringify(opts.defaultLocale)
  var key = JSON.stringify(opts.cookieKey)
  return [
    '(function(){try{',
    'if(location.pathname!=="/")return;',
    'if(' + CRAWLER_UA_RE.toString() + '.test(navigator.userAgent||""))return;',
    'var r=(' + resolveRootLocale.toString() + ')({',
    'cookie:document.cookie,cookieKey:' + key + ',',
    'languages:navigator.languages||[navigator.language],',
    'supported:' + supported + ',defaultLocale:' + def + '});',
    // `/<code>` (no trailing slash) is the canonical i18n route — the same
    // form switchLocalePath emits — and what Firebase cleanUrls serves
    // directly; `/<code>/` would cost an extra 301 hop on hosting.
    // window.__spoolLeaving: the later head scripts (signed-out redirect,
    // early session probe) stay home while this document is replaced.
    'if(r&&r!==' + def + '){try{window.__spoolLeaving=1}catch(e){}location.replace("/"+r+location.search+location.hash);}',
    '}catch(e){}})();',
  ].join('')
}
