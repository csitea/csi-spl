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
