/**
 * Tenant hosts (SPL-959, owner option B 2026-09-26: "only the spool-hub should
 * be without the subdomain").
 *
 * The apex https://<fqdn> (siteUrl, NUXT_PUBLIC_SITE_URL) is the apex tenant
 * (NUXT_PUBLIC_TENANT, t1). Every other tenant is https://<tenant>.<fqdn>.
 * The page's host names the tenant it shows. The hub reads the same
 * thing from the Origin header of each request, and still requires membership.
 * One session cookie (Domain=<base>) signs in every host of the env.
 *
 * Pure: every function takes the URLs it reads. '' / null means "not a
 * tenant host", and the caller then keeps the specs/026 behaviour.
 */
import { validTenant } from './tenant.mjs'
import { pageTenant, siteHostOf } from './tenant-host-core.mjs'

export { isTenantHostOf, pageTenant, siteHostOf } from './tenant-host-core.mjs'

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

/** https://<tenant host> of a tenant: the apex for the apex tenant. '' when invalid. */
export function tenantOrigin(tenant, siteUrl, apexTenant) {
  const site = siteHostOf(siteUrl)
  const t = String(tenant || '')
  if (!site || !validTenant(t)) return ''
  return t === apexTenant ? 'https://' + site : 'https://' + t + '.' + site
}

/** The same path (+ query + hash) on the tenant's host. '' when the tenant is invalid. */
export function tenantUrl(tenant, siteUrl, apexTenant, path = '/') {
  const origin = tenantOrigin(tenant, siteUrl, apexTenant)
  if (!origin) return ''
  const p = String(path || '/')
  return origin + (p.startsWith('/') && !p.startsWith('//') ? p : '/')
}

/* Pages that name something only ONE tenant has: a channel, a DM peer, a topic. */
const TENANT_SCOPED = new Set(['channel', 'dm', 't'])
const LOCALE_SEG_RE = /^[a-z]{2}(?:-[a-z]{2,4})?$/i

/**
 * The path a tenant switch carries to the other tenant's host.
 * A page that means the same in every tenant (/lobby, /issues, /settings/...)
 * is kept; /channel/<x>, /dm/<x> and /t/<id> name something of the OLD tenant
 * and go to that locale's home instead. Measured on prd 2026-09-27: a switch
 * from one tenant's /channel/development to another tenant landed on
 * /channel/development there - a channel the other tenant does not have - and
 * every send was refused (unknown_channel) as "did not reach the hub".
 */
export function switchPath(path) {
  const p = String(path || '/')
  if (!p.startsWith('/') || p.startsWith('//')) return '/'
  const segs = p.split(/[?#]/)[0].split('/').filter(Boolean)
  if (segs.length && TENANT_SCOPED.has(segs[0])) return '/'
  if (segs.length > 1 && LOCALE_SEG_RE.test(segs[0]) && TENANT_SCOPED.has(segs[1])) return '/' + segs[0]
  return p
}

/**
 * The hop on arrival at the apex with ?tenant=<t> (t valid, not the apex
 * tenant): the same path on t's host, without the tenant param. Sign-in
 * returns through the apex (the OAuth callbacks are registered there), and a
 * tenant host sends it back this way. '' = stay.
 */
export function tenantParamHop(href, siteUrl, apexTenant) {
  let u
  try {
    u = new URL(String(href || ''))
  } catch {
    return ''
  }
  if (pageTenant(u.hostname, siteUrl, apexTenant) !== apexTenant || !apexTenant) return ''
  const t = String(u.searchParams.get('tenant') || '').trim().toLowerCase()
  if (!validTenant(t) || t === apexTenant) return ''
  u.searchParams.delete('tenant')
  return tenantUrl(t, siteUrl, apexTenant, u.pathname + u.search + u.hash)
}

/**
 * The topic / message uuid an old link carries: ?topic=, ?thread=, ?in=, or
 * /t/<uuid> (after an optional locale prefix). '' when none.
 */
export function oldLinkId(href) {
  let u
  try {
    u = new URL(String(href || ''), 'https://x.invalid')
  } catch {
    return ''
  }
  for (const k of ['topic', 'thread', 'in']) {
    const v = String(u.searchParams.get(k) || '').toLowerCase()
    if (UUID_RE.test(v)) return v
  }
  const m = /^(?:\/[a-z]{2}(?:-[a-z]{2,4})?)?\/t\/([0-9a-f-]{36})\/?$/i.exec(u.pathname)
  return m && UUID_RE.test(m[1].toLowerCase()) ? m[1].toLowerCase() : ''
}

/**
 * Where a signed-in human who is NOT a member of the page's tenant goes:
 * the membership switched into last (last_active_at), else the first one.
 * '' = stay (no session tenants, or already a member).
 */
export function homeTenant(claims, page) {
  const list = claims && Array.isArray(claims.tenants) ? claims.tenants : []
  const ids = list.map((t) => (t && typeof t.tenant_id === 'string' ? t.tenant_id : '')).filter(validTenant)
  if (!ids.length || ids.includes(page)) return ''
  let best = ''
  let at = ''
  for (const t of list) {
    const ts = t && typeof t.last_active_at === 'string' ? t.last_active_at : ''
    if (ts && ts > at && validTenant(t.tenant_id)) { best = t.tenant_id; at = ts }
  }
  return best || ids[0]
}
