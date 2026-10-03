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
// perf round 4 W10 (round-3 P3-28): the edge picks the locale first.
// Firebase Hosting i18n (`hosting.i18n.root`, rendered by
// csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh) answers `/`
// with `/localized-files/<code>_ALL/index.html`, a copy of the prerendered
// `/<code>` page, chosen by the `firebase-language-override` cookie, else
// by Accept-Language. When that document is the locale `resolveRootLocale`
// picks, the script only renames the URL to `/<code>`
// (`history.replaceState`, before the router reads it): one document, not
// two. `location.replace` stays the fallback for when the cookie wins over
// what the edge served. Every page mirrors the locale cookie into
// `firebase-language-override`, so the edge itself honours the choice on
// the next visit and the cookie keeps beating Accept-Language.
//
// Plain ES5 on purpose: the function body is serialised with `toString()`
// and shipped verbatim to every browser, so no spread/arrow/const.
// Unit-tested by tests/unit/root-locale-redirect.test.mjs.

/**
 * Crawlers are exempt: `/` stays the default-locale home (the WUI is
 * noindex and ships no hreflang alternates since perf round 3 P3-22).
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

/** The cookie Firebase Hosting i18n reads before Accept-Language. */
export const EDGE_LOCALE_COOKIE = 'firebase-language-override'

/**
 * One cookie value by exact name, URL-decoded; '' when absent.
 *
 * @param {string} cookie raw `document.cookie`
 * @param {string} key    cookie name
 * @returns {string}
 */
export function readCookie(cookie, key) {
  var parts = String(cookie || '').split(';')
  for (var p = 0; p < parts.length; p++) {
    var kv = parts[p]
    var eq = kv.indexOf('=')
    if (eq < 0 || kv.slice(0, eq).replace(/^\s+|\s+$/g, '') !== key) continue
    var val = kv.slice(eq + 1).replace(/^\s+|\s+$/g, '')
    try { val = decodeURIComponent(val) } catch (e) { /* keep raw */ }
    return val
  }
  return ''
}

/**
 * Build the inline, blocking <head> script for nuxt.config `app.head.script`.
 *
 * On every page: mirror the locale cookie into EDGE_LOCALE_COOKIE.
 * On the exact root path only:
 *   - the document's own locale (`<html lang>`, which the edge chose) is
 *     the resolved one: rename the URL to `/<code>` when it is not the
 *     default; no second document.
 *   - otherwise (the cookie disagrees with what the edge served): the old
 *     `location.replace("/<code>")`, or, for the default locale, a reload of
 *     `/` with the edge cookie already set (once per tab, so a host that
 *     ignores the cookie can never loop).
 * Crawlers never navigate; they keep the document they were served.
 *
 * @param {{ supported: string[], defaultLocale: string, cookieKey: string }} opts
 * @returns {string} JavaScript source
 */
export function buildRootLocaleRedirectScript(opts) {
  var supported = JSON.stringify(opts.supported)
  var def = JSON.stringify(opts.defaultLocale)
  var key = JSON.stringify(opts.cookieKey)
  var edge = JSON.stringify(EDGE_LOCALE_COOKIE)
  var setEdge = 'document.cookie=' + edge + '+"="+%s+"; Path=/; Max-Age=31536000; SameSite=Lax"+(location.protocol==="https:"?"; Secure":"");'
  return [
    '(function(){try{',
    'var S=' + supported + ',D=' + def + ',c=String(document.cookie||""),',
    'rc=(' + readCookie.toString() + '),k=rc(c,' + key + ');',
    // Mirror the choice for the edge (c is read first: a write changes what
    // document.cookie returns).
    'if(S.indexOf(k)>=0&&rc(c,' + edge + ')!==k)' + setEdge.replace('%s', 'k'),
    'if(location.pathname!=="/")return;',
    'var de=document.documentElement,h=String(de&&de.lang||"").toLowerCase().split("-")[0],',
    'v=S.indexOf(h)>=0?h:D,t=location.search+location.hash;',
    'var r=' + CRAWLER_UA_RE.toString() + '.test(navigator.userAgent||"")?v:(' + resolveRootLocale.toString() + ')({',
    'cookie:c,cookieKey:' + key + ',',
    'languages:navigator.languages||[navigator.language],',
    'supported:S,defaultLocale:D});',
    // `/<code>` (no trailing slash) is the canonical i18n route — the same
    // form switchLocalePath emits — and what Firebase cleanUrls serves
    // directly; `/<code>/` would cost an extra 301 hop on hosting.
    'if(r===v){if(v!==D)history.replaceState(null,"","/"+v+t);return;}',
    'if(r===D){try{if(sessionStorage.getItem("spoolRootLocale"))return;sessionStorage.setItem("spoolRootLocale","1")}catch(x){return}',
    setEdge.replace('%s', 'D') + '}',
    // window.__spoolLeaving: the later head scripts (signed-out redirect,
    // early session probe) stay home while this document is replaced.
    'try{window.__spoolLeaving=1}catch(e){}location.replace("/"+(r===D?"":r)+t);',
    '}catch(e){}})();',
  ].join('')
}
