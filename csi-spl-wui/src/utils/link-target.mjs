/**
 * Where a link in a message or a description opens.
 *
 * Same tab: a relative URL, or an absolute URL on this site
 * (spool-hub.ai, www.spool-hub.ai).
 * Another tab: everything else. The dev environment (dev.spool-hub.ai)
 * is external even though it shares the site name.
 */
const INTERNAL_HOSTS = new Set(['spool-hub.ai', 'www.spool-hub.ai'])

export function opensNewTab(href) {
  const raw = String(href || '').trim()
  if (!raw) return true
  if (raw.startsWith('#') || raw.startsWith('?') || (raw.startsWith('/') && !raw.startsWith('//'))) return false
  let url
  try {
    url = new URL(raw)
  } catch {
    return true
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return true
  if (url.hostname === 'dev.spool-hub.ai') return true
  return !INTERNAL_HOSTS.has(url.hostname)
}

/** Attributes for a rendered anchor. External links name a new tab. */
export function linkAttrs(href) {
  if (opensNewTab(href)) return { target: '_blank', rel: 'noopener noreferrer nofollow' }
  return { rel: 'nofollow' }
}

/** The same attributes as a string, for the HTML the tests render. */
export function linkAttrHtml(href) {
  const a = linkAttrs(href)
  const parts = []
  if (a.target) parts.push(`target="${a.target}"`)
  if (a.rel) parts.push(`rel="${a.rel}"`)
  return parts.join(' ')
}
