/**
 * The fixed tenant drop box (one row; choosing it changes nothing).
 *
 * The signed-in session names the tenant: `active_tenant`, else the bound
 * `t` claim, else the only membership. A display name on that membership
 * (`display_name`, else `name`) or a session `tenant_name` is the label;
 * otherwise the label is the id. `configured` is the client's tenant
 * (the ?tenant= choice, else NUXT_PUBLIC_TENANT) and is used only when the
 * session names none — it never borrows another membership's name.
 * `{ id: '', label: '' }` when nothing names a tenant. The caller still
 * draws one option.
 *
 * @param {unknown} claims session claims, or null
 * @param {unknown} [configured]
 * @returns {{ id: string, label: string }}
 */
export function fixedTenantOption(claims, configured = '') {
  const c = claims && typeof claims === 'object' ? claims : {}
  const str = (v) => (typeof v === 'string' ? v.trim() : '')
  const list = Array.isArray(c.tenants) ? c.tenants.filter((t) => t && typeof t === 'object') : []
  const active = str(c.active_tenant) || str(c.t)
  let row = active ? list.find((t) => str(t.tenant_id) === active) || null : null
  if (!row && !active && list.length === 1) row = list[0]
  const sessionId = active || str(row && row.tenant_id)
  const id = sessionId || str(configured)
  const sessionName = str(row && row.display_name) || str(row && row.name) || (sessionId ? str(c.tenant_name) : '')
  return { id, label: sessionName || id }
}
