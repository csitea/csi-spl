/**
 * The in-app help (W14, spec 047, SPL-1169): /help serves the pages of
 * csi-spl-doc/doc/help, copied into src/public/help-md by
 * src/node/help/sync-help.mjs. A page links its siblings as `./x.md`; here
 * such a link becomes the /help/x route, and any other relative link points
 * at the file in the public repository. Node tests import this file.
 */

/** Where a relative link that is not a help page resolves: the repo copy of doc/help. */
export const HELP_REPO_BASE = 'https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/help/'

/** A help page slug the copy can hold (the sync script's file rule). */
export function validHelpSlug(s) {
  return typeof s === 'string' && /^[a-z0-9-]{1,80}$/.test(s)
}

/**
 * One link target as the /help page shows it. `route(slug)` builds the
 * in-app path (the page passes its locale-aware one).
 */
export function helpHref(raw, route = (slug) => '/help/' + slug) {
  const s = String(raw ?? '').trim()
  if (!s) return s
  /* absolute, mailto, same-page anchor or site path: unchanged */
  if (/^[a-z][a-z0-9+.-]*:/i.test(s) || s.startsWith('#') || s.startsWith('/')) return s
  const m = /^(?:\.\/)?([a-z0-9-]+)\.md(?:#.*)?$/.exec(s)
  if (m) return route(m[1] === 'index' ? '' : m[1]).replace(/\/$/, '')
  try {
    return new URL(s, HELP_REPO_BASE).href
  } catch {
    return s
  }
}

/** The markdown with every inline link target rewritten by helpHref. */
export function rewriteHelpLinks(md, route) {
  return String(md ?? '').replace(/\]\(([^)\s]+)\)/g, (_, href) => '](' + helpHref(href, route) + ')')
}
