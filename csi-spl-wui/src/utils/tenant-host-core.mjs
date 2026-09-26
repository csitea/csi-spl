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
 * This file is the EAGER core (the page's tenant, the link rule): the initial
 * JS chunk is at its 027 budget, so everything else lives in
 * tenant-host.mjs, loaded lazily.
 *
 * Pure: every function takes the URLs it reads. '' / null means "not a
 * tenant host", and the caller then keeps the specs/026 behaviour.
 */
import { validTenant } from './tenant.mjs'

/** The apex host of an https siteUrl ('' when not one). */
export function siteHostOf(siteUrl) {
  try {
    const u = new URL(String(siteUrl || ''))
    if (u.protocol !== 'https:' || u.port || !u.hostname) return ''
    return u.hostname.toLowerCase()
  } catch {
    return ''
  }
}

/**
 * The tenant a page host shows: the apex -> apexTenant, <t>.<apex> -> t
 * (one valid, non-reserved label), anything else ('localhost', another
 * env) -> ''.
 */
export function pageTenant(hostname, siteUrl, apexTenant) {
  const site = siteHostOf(siteUrl)
  const host = String(hostname || '').toLowerCase()
  if (!site || !host) return ''
  if (host === site) return validTenant(apexTenant) ? String(apexTenant) : ''
  if (!host.endsWith('.' + site)) return ''
  const label = host.slice(0, -site.length - 1)
  return validTenant(label) ? label : ''
}

/**
 * Whether url is a page host of THIS env: the apex or one tenant label under
 * it, https and no port. The api host and the other env are not ("api" and
 * "dev" are reserved labels, x.dev is two labels).
 */
export function isTenantHostOf(url, siteUrl) {
  let u
  try {
    u = new URL(String(url || ''))
  } catch {
    return false
  }
  if (u.protocol !== 'https:' || u.port) return false
  const site = siteHostOf(siteUrl)
  if (!site) return false
  const host = u.hostname.toLowerCase()
  if (host === site) return true
  if (!host.endsWith('.' + site)) return false
  return validTenant(host.slice(0, -site.length - 1))
}
