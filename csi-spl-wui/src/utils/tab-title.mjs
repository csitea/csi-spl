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

/**
 * Bug A (t1 5002067f): a background tab gave no sign of a new message. The
 * unread total leads the title, "(3) hooli.spool-hub", as a chat tab does.
 * Muted channels do not count: they are the ones the reader asked to ignore.
 *
 * @param {Record<string, number>} unread per key (`ch:<slug>` / `dm:<peer>`)
 * @param {string[]} [muted] muted channel slugs
 */
export function unreadTotal(unread, muted = []) {
  const off = new Set((muted || []).map((c) => `ch:${c}`))
  let n = 0
  for (const [k, v] of Object.entries(unread || {})) {
    if (!off.has(k)) n += Math.max(0, Number(v) || 0)
  }
  return n
}

/** "(n) <title>"; over 99 reads "(99+)"; zero leaves the title alone. */
export function withUnread(title, n) {
  const v = Number(n) || 0
  if (v <= 0) return String(title || '')
  return `(${v > 99 ? '99+' : v}) ${title}`
}
