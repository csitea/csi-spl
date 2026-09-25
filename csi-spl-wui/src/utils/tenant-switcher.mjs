/**
 * The tenant drop box's single row: the tenant of the session.
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

/**
 * The drop box rows (specs/026 §6, the workspace switcher). A session with
 * two or more memberships lists every one of them (label as above, else the
 * id), selected = the active tenant; with none active a blank first row keeps
 * the box honest until the human picks one. Anything else is the single
 * fixedTenantOption row, and `canSwitch` is false: choosing it does nothing.
 *
 * @param {unknown} claims session claims, or null
 * @param {unknown} [configured]
 * @returns {{ selected: string, canSwitch: boolean, options: { id: string, label: string }[] }}
 */
export function tenantSwitchOptions(claims, configured = '') {
  const c = claims && typeof claims === 'object' ? claims : {}
  const str = (v) => (typeof v === 'string' ? v.trim() : '')
  const seen = new Set()
  const rows = []
  for (const t of Array.isArray(c.tenants) ? c.tenants : []) {
    const id = t && typeof t === 'object' ? str(t.tenant_id) : ''
    if (!id || seen.has(id)) continue
    seen.add(id)
    rows.push({ id, label: str(t.display_name) || str(t.name) || id })
  }
  if (rows.length < 2) {
    const one = fixedTenantOption(claims, configured)
    return { selected: one.id, canSwitch: false, options: [one] }
  }
  const active = str(c.active_tenant) || str(c.t)
  const selected = seen.has(active) ? active : ''
  return { selected, canSwitch: true, options: selected ? rows : [{ id: '', label: '' }, ...rows] }
}
