// localeTargetPath — where a locale switch has to land, computed from the URL.
//
// WHY THIS EXISTS
//
// `switchLocalePath()` is the module's answer to "this page in locale X", and
// it is the right first choice: it knows the route's name and params, so a
// dynamic route (`/channel/[name]`) keeps them. But it derives that answer
// from `route.name`, and it returns an EMPTY STRING when the name is not a
// localised one it recognises. Both callers used to paper over that with
//
//     const pathOnly = (switched || route.path).split(/[?#]/)[0]
//
// which turns "I don't know" into "stay exactly where you are" — `navigateTo`
// is then handed the current path, vue-router sees a duplicate navigation and
// does nothing, and the switcher is a no-op the user reads as "the dropdown
// is broken". Measured against dev.<fqdn> on 2026-09-22, tree 021d706, the
// header switcher took that branch on 1 of 13 runs (`lang` flipped to fi-FI
// while the URL stayed on the default-locale route, no history entry written).
//
// So the module's answer is now CHECKED rather than trusted: if it does not
// carry the prefix the target locale must have, this pure function rebuilds
// the path from the URL instead. It is prefix arithmetic only — strip the
// locale segment the path currently carries, add the one it should — which is
// exactly what `prefix_except_default` encodes, and it cannot return the path
// it was given for a different locale.
//
// Unit-tested by tests/unit/locale-target-path.test.mjs.

/** The locale segment a path currently carries, or '' when it carries none. */
export function localePrefixOf(path, codes) {
  const seg = String(path || '/').split(/[?#]/)[0].split('/')[1] || ''
  return (codes || []).includes(seg) ? seg : ''
}

/**
 * True when `path` is already in `code` under `prefix_except_default`: the
 * default locale is the one with NO prefix, every other locale has its own.
 */
export function isPathInLocale(path, code, codes, defaultLocale) {
  return localePrefixOf(path, codes) === (code === defaultLocale ? '' : code)
}

/**
 * The same page, in `code`.
 *
 * @param {string} path           current route path (no query, no hash)
 * @param {string} code           target locale code
 * @param {string[]} codes        every shipped locale code
 * @param {string} defaultLocale  the unprefixed locale
 * @returns {string} a rooted path, always in `code`
 */
export function localeTargetPath(path, code, codes, defaultLocale) {
  const clean = String(path || '/').split(/[?#]/)[0] || '/'
  const current = localePrefixOf(clean, codes)
  // Drop the locale segment this path carries, keeping the rest verbatim.
  const bare = current ? clean.slice(current.length + 1) || '/' : clean
  if (code === defaultLocale) return bare.startsWith('/') ? bare : '/' + bare
  return ('/' + code + (bare === '/' ? '' : bare)) || '/'
}
