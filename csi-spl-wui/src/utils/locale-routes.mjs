// Locale route copies, made at router creation instead of shipped (CLE-77925).
//
// @nuxtjs/i18n (prefix_except_default) writes one route per page PER LOCALE
// into the generated routes module: 31 pages x 19 locales = 589 records, each
// with its own lazy import and preload list: 78 KB raw (2.5 KB gzip) of the
// initial JS, parsed on every first load. The build keeps only the default-locale records
// (nuxt.config.ts, localeRouteCopiesModule, which also proves that
// expandLocaleRoutes rebuilds exactly what it removed), and
// src/app/router.options.ts calls expandLocaleRoutes when the router is made.
//
// The copy of `name___<default>` at `/path` for locale `bg` is `name___bg` at
// `/bg/path` (`/` -> `/bg`); a child keeps its relative path and is renamed
// the same way. Component, meta, alias and redirect are shared.

const SEP = "___"

function isDefaultRecord(route, defaultLocale) {
  return typeof route.name === "string" && route.name.endsWith(SEP + defaultLocale)
}

/** One record (and its children) renamed from the default locale to `code`. */
function localeCopy(route, code, defaultLocale, top) {
  const out = { ...route }
  if (isDefaultRecord(route, defaultLocale)) {
    out.name = route.name.slice(0, -defaultLocale.length) + code
  }
  if (top) out.path = route.path === "/" ? `/${code}` : `/${code}${route.path}`
  if (Array.isArray(route.children)) {
    out.children = route.children.map((c) => localeCopy(c, code, defaultLocale, false))
  }
  return out
}

/**
 * Default-locale route records -> those records plus one prefixed copy per
 * other locale, in i18n's order (per page, every locale in `codes` order; the
 * default one is the record itself, unprefixed). Other records pass through.
 * @param {Array<Record<string, any>>} routes
 * @param {string[]} codes locale codes, i18n config order
 * @param {string} defaultLocale
 */
export function expandLocaleRoutes(routes, codes, defaultLocale) {
  const out = []
  for (const r of routes) {
    if (!isDefaultRecord(r, defaultLocale)) {
      out.push(r)
      continue
    }
    for (const code of codes) {
      out.push(code === defaultLocale ? r : localeCopy(r, code, defaultLocale, true))
    }
  }
  return out
}

/** True for a record i18n made for a locale other than the default. */
export function isLocaleRouteCopy(route, codes, defaultLocale) {
  if (typeof route.name !== "string") return false
  const i = route.name.lastIndexOf(SEP)
  if (i < 0) return false
  const code = route.name.slice(i + SEP.length)
  return code !== defaultLocale && codes.includes(code)
}

// ── Active locale first (perf round 3, P3-14) ─────────────────────────────
// Building the vue-router matcher for all 494 top-level records costs about
// 4x what the ~69 records of two locales cost (node, warm, n=3: 3.5..4.6 vs
// 0.8..1.3 ms per createRouter; the audit saw 32 ms CPU 4x in the browser).
// So the browser router starts with the default locale, the locale in the
// URL and every record that belongs to no locale; the other locales' records
// are added with router.addRoute later (registerLocaleRoutes): at idle after
// mount, before a locale switch, and from a guard when a navigation matches
// nothing. The server (prerender) keeps building all of them at once.

/** The locale a record belongs to: its name's suffix, else that of its first
 *  named child (i18n's per-locale parents of a nested page have no name). */
function recordLocale(route, codes) {
  if (typeof route.name === "string") {
    const i = route.name.lastIndexOf(SEP)
    const code = i < 0 ? "" : route.name.slice(i + SEP.length)
    return codes.includes(code) ? code : ""
  }
  for (const c of route.children || []) {
    const code = recordLocale(c, codes)
    if (code) return code
  }
  return ""
}

/**
 * expandLocaleRoutes, split in two: `now` holds the records of the default
 * locale, of `active` and of no locale, in i18n's order; `later()` builds the
 * rest (made only when called). now + later() is expandLocaleRoutes' set.
 * @param {Array<Record<string, any>>} routes default-locale records (as kept by the build)
 * @param {string[]} codes
 * @param {string} defaultLocale
 * @param {string} active the locale the first route is in ('' = default)
 */
export function splitLocaleRoutes(routes, codes, defaultLocale, active) {
  const keep = (code) => !code || code === defaultLocale || code === active
  const now = []
  for (const r of routes) {
    if (!isDefaultRecord(r, defaultLocale)) {
      if (keep(recordLocale(r, codes))) now.push(r)
      continue
    }
    for (const code of codes) {
      if (keep(code)) now.push(code === defaultLocale ? r : localeCopy(r, code, defaultLocale, true))
    }
  }
  const later = () => expandLocaleRoutes(routes, codes, defaultLocale).filter((r) => !keep(recordLocale(r, codes)))
  return { now, later }
}

let pendingLocaleRoutes = null

/** Remember the records the router was made without (router.options.ts). */
export function deferLocaleRoutes(later) {
  pendingLocaleRoutes = later
}

/**
 * Add the deferred locale records to `router`, once. True when it added
 * any (the caller then re-resolves what it was looking for).
 * @param {{ addRoute: (r: any) => unknown }} router
 */
export function registerLocaleRoutes(router) {
  const later = pendingLocaleRoutes
  if (!later) return false
  pendingLocaleRoutes = null
  for (const r of later()) router.addRoute(r)
  return true
}
