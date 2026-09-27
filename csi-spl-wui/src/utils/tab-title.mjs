/**
 * The browser tab's title (owner, topic d1f76e76, 2026-09-26): "the text on
 * the chrome tabs for each tab should be <tenant-name>.spool-hub". The name
 * is the tenant's DISPLAY name, the one in the tenant drop box
 * (fixedTenantOption), e.g. "hooli.spool-hub". The apex tenant (t1, whose
 * display name is itself "spool-hub") is plain "spool-hub". A page title, when
 * a page sets one, stays in front: "Search: x · hooli.spool-hub".
 */
import { fixedTenantOption } from './tenant-switcher.mjs'

export const PRODUCT = 'spool-hub'

/** "<display name>.spool-hub", or "spool-hub" for the apex tenant / no tenant. */
export function tenantTabName(claims, pageTenant, apexTenant) {
  const { id, label } = fixedTenantOption(claims, pageTenant)
  const name = String(label || id || '').trim()
  if (!name || id === apexTenant || name === PRODUCT) return PRODUCT
  return `${name}.${PRODUCT}`
}

/** The whole <title>: an optional page title, then the tenant tab name. */
export function tabTitle(pageTitle, tabName) {
  const page = String(pageTitle || '').trim()
  const tail = String(tabName || PRODUCT)
  return page && page !== tail && page !== PRODUCT ? `${page} · ${tail}` : tail
}
