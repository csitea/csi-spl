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

/**
 * The drop box's hover explanation (CLE-34991): which tenant this is, what a
 * tenant is, and whether picking another one switches. `t` is the i18n
 * translate function; keys sidebar.tenant_hint ({name}), then
 * sidebar.tenant_hint_switch when the box can switch, else
 * sidebar.tenant_hint_one. With no tenant named, {name} is the "Tenant"
 * caption itself rather than an empty slot.
 *
 * @param {{ selected: string, canSwitch: boolean, options: { id: string, label: string }[] }} box
 * @param {(key: string, params?: Record<string, string>) => string} t
 * @returns {string}
 */
export function tenantHint(box, t) {
  const opts = box && Array.isArray(box.options) ? box.options : []
  const row = opts.find((o) => o && o.id === (box && box.selected))
  const name = (row && (row.label || row.id)) || t('sidebar.tenant')
  const tail = box && box.canSwitch ? t('sidebar.tenant_hint_switch') : t('sidebar.tenant_hint_one')
  return t('sidebar.tenant_hint', { name }) + ' ' + tail
}

/** The UA dropdown arrow, in px. The gap before it is the owner's 3px. */
export const TENANT_SELECT_ARROW_PX = 16
export const TENANT_SELECT_GAP_PX = 3

/**
 * Select width so the arrow sits 3px after the widest tenant name.
 * `textWidthPx` is the measured width of that name in the select's font.
 * @param {number} textWidthPx
 * @returns {number}
 */
export function tenantSelectWidthPx(textWidthPx) {
  const w = Number.isFinite(textWidthPx) && textWidthPx > 0 ? textWidthPx : 0
  return Math.ceil(w) + TENANT_SELECT_GAP_PX + TENANT_SELECT_ARROW_PX
}
