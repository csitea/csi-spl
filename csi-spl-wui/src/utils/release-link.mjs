/**
 * A release-note URL of this spool opens inside the app (owner, t1 topic
 * a1bce52e: "Every release note link or whatever should become an internal
 * link. The host name should not be seen, and it should have a small
 * preview").
 *
 * Lane posts carry https://<env fqdn>/releases/<sha> for dev AND prd
 * (do_release_note_link). The prd page saw the dev one as another site (a
 * new tab, the host in the text) and a tenant host saw the apex one as
 * another origin, which a phone tap did not open. A release note is the same
 * commit in every env and every workspace, so any of those URLs becomes this
 * page's own /releases/<ref>: same tab, the router, no host.
 *
 * "Of this spool" = the host is the base domain or under it. The base is the
 * env apex (siteUrl, else the page host) with a leading env label (dev, lde)
 * dropped: prd serves the base itself, dev and lde serve <env>.<base>
 * (cnf env.dns.fqdn). No domain literal: both come from the runtime page.
 *
 * Pure. Kept tiny: link-target.mjs is in the initial chunk.
 */

const ENV_LABEL_RE = /^(?:dev|lde)\./
const REF = '[0-9a-f]{7,40}|v[0-9]{1,6}\\.[0-9]{1,6}\\.[0-9]{1,6}(?:-c[0-9]{1,4})?'
const PATH_RE = new RegExp(`^(?:/[a-z]{2}(?:-[a-z]{2})?)?/releases/(${REF})/?$`, 'i')

function hostOf(url) {
  try {
    return new URL(String(url || '')).hostname.toLowerCase()
  } catch {
    return ''
  }
}

/** The base domain every env of this spool lives under, '' when unknown. */
export function spoolBaseHost(pageOrigin, siteUrl) {
  const host = hostOf(siteUrl) || hostOf(pageOrigin)
  return host.replace(ENV_LABEL_RE, '')
}

/** The ref of a /releases/<ref> path (locale prefix allowed), or ''. */
export function releaseRefOfPath(pathname) {
  const m = PATH_RE.exec(String(pathname || ''))
  return m ? m[1].toLowerCase() : ''
}

/**
 * This page's own path for a release-note URL of any env of this spool, or
 * null when the URL is not one.
 * @param {URL} u an absolute http(s) URL
 * @param {string} pageOrigin
 * @param {string} [siteUrl]
 */
export function localReleasePath(u, pageOrigin, siteUrl) {
  if (!u || (u.protocol !== 'http:' && u.protocol !== 'https:') || u.search || u.username || u.password) return null
  const base = spoolBaseHost(pageOrigin, siteUrl)
  const host = u.hostname.toLowerCase().replace(/^www\./, '')
  if (!base || (host !== base && !host.endsWith('.' + base))) return null
  const ref = releaseRefOfPath(u.pathname)
  return ref ? '/releases/' + ref : null
}
