/**
 * The in-app help (W14, spec 047, SPL-1169): /help serves the pages of
 * csi-spl-doc/doc/help, copied into src/public/help-md by
 * src/node/help/sync-help.mjs. A page links its siblings as `./x.md`; here
 * such a link becomes the /help/x route, and any other relative link points
 * at the file in the source repository: helpRepoBase() from cnf
 * env.wui.repo_web_url + env.wui.repo_help_path (/config.json repoWebUrl,
 * repoHelpPath). Either unset = no repository: such a link is dropped and
 * its text stays. Node tests import this file.
 */

/** Where a relative link that is not a help page resolves, or '' (none). */
export function helpRepoBase(webUrl, helpPath) {
  const b = String(webUrl ?? '').trim().replace(/\/+$/, '')
  const p = String(helpPath ?? '').trim()
  if (!/^https?:\/\/[^\s"'<>]+$/i.test(b) || !/^\/[^\s"'<>?#]*\/$/.test(p)) return ''
  return b + p
}

/** A help page slug the copy can hold (the sync script's file rule). */
export function validHelpSlug(s) {
  return typeof s === 'string' && /^[a-z0-9-]{1,80}$/.test(s)
}

/**
 * One link target as the /help page shows it. `route(slug)` builds the
 * in-app path (the page passes its locale-aware one); `repoBase` is
 * helpRepoBase(). A repo link with no repoBase is '' (hidden).
 */
export function helpHref(raw, route = (slug) => '/help/' + slug, repoBase = '') {
  const s = String(raw ?? '').trim()
  if (!s) return s
  /* absolute, mailto, same-page anchor or site path: unchanged */
  if (/^[a-z][a-z0-9+.-]*:/i.test(s) || s.startsWith('#') || s.startsWith('/')) return s
  const m = /^(?:\.\/)?([a-z0-9-]+)\.md(?:#.*)?$/.exec(s)
  if (m) return route(m[1] === 'index' ? '' : m[1]).replace(/\/$/, '')
  if (!repoBase) return ''
  try {
    return new URL(s, repoBase).href
  } catch {
    return ''
  }
}

/**
 * The copy's host tokens filled in (src/node/help/sync-help.mjs writes them
 * where doc/help names the hosted domain): {{api}} = this site's hub host,
 * {{site}} = this site's own host. A token with no value stays readable.
 */
export function fillHelpHosts(md, { api = '', site = '' } = {}) {
  return String(md ?? '')
    .replace(/\{\{api\}\}/g, api || site || 'your-hub')
    .replace(/\{\{site\}\}/g, site || 'your-site')
}

/** The host of a URL ('' when it is not one). */
export function hostOf(url) {
  try { return new URL(String(url || '')).host } catch { return '' }
}

/**
 * The markdown with every inline link target rewritten by helpHref; a link
 * helpHref hides keeps only its text.
 */
export function rewriteHelpLinks(md, route, repoBase = '') {
  return String(md ?? '').replace(/(!?)\[([^\]\n]*)\]\(([^)\s]+)\)/g, (all, bang, text, href) => {
    const to = helpHref(href, route, repoBase)
    if (to) return bang + '[' + text + '](' + to + ')'
    return bang ? '' : text
  })
}
