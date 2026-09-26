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


/** Px between the end of the widest drawn name and the start of the arrow. */
export const TENANT_ARROW_GAP_PX = 3

/** SPL-980: px of the select's own background before and after the name
 *  (the name no longer touches the box's edge). The select is this much
 *  wider on each side, and the flex gap to the arrow is this much smaller,
 *  so the arrow still sits TENANT_ARROW_GAP_PX after the name. */
export const TENANT_TEXT_PAD_PX = 2

/**
 * The strings the closed control actually draws. A blank option shows
 * `fallback` (the Tenant caption), the same substitution as the option text
 * (`label || fallback`).
 *
 * @param {unknown} options
 * @param {unknown} fallback
 * @returns {string[]}
 */
export function tenantDrawnLabels(options, fallback) {
  const fb = String(fallback ?? '')
  const list = Array.isArray(options) ? options : []
  return list.map((o) => {
    const label = o && typeof o === 'object' && typeof o.label === 'string' ? o.label : ''
    return label || fb
  })
}

/**
 * Rendered width of the widest label. `measure(label)` returns px in the
 * control's own font. Non-finite results are skipped. An empty list is 0.
 *
 * @param {unknown} labels
 * @param {(label: string) => number} measure
 * @returns {number}
 */
export function widestLabelWidth(labels, measure) {
  let widest = 0
  const list = Array.isArray(labels) ? labels : []
  for (const label of list) {
    const n = Number(measure(String(label ?? '')))
    if (Number.isFinite(n) && n > widest) widest = n
  }
  return widest
}

/**
 * Closed select width: the widest label, then `gapPx` (default 3), then the
 * arrow. The label width is measured by the caller. This does not invent one.
 *
 * @param {unknown} widestTextPx
 * @param {unknown} arrowPx
 * @param {unknown} [gapPx]
 * @returns {number}
 */
export function tenantClosedWidthPx(widestTextPx, arrowPx, gapPx = TENANT_ARROW_GAP_PX) {
  const text = Number(widestTextPx)
  const arrow = Number(arrowPx)
  const gap = Number(gapPx)
  if (!Number.isFinite(text) || text < 0) return NaN
  if (!Number.isFinite(arrow) || arrow < 0) return NaN
  if (!Number.isFinite(gap) || gap < 0) return NaN
  return text + gap + arrow
}

/**
 * Gap between the end of a label `widestPx` wide and the arrow's near edge.
 * LTR: the arrow's left minus the label's end. RTL: the label's end minus
 * the arrow's right. `padStartPx` is the select's padding-inline-start.
 *
 * @param {{ selLeft: number, selRight: number, padStartPx?: number, widestPx: number, arrowLeft: number, arrowRight: number, direction?: string }} box
 * @returns {number}
 */
export function tenantNameArrowGapPx(box) {
  const b = box && typeof box === 'object' ? box : {}
  const pad = Number(b.padStartPx) || 0
  const widest = Number(b.widestPx)
  if (!Number.isFinite(widest)) return NaN
  const rtl = b.direction === 'rtl'
  const nameEnd = rtl ? Number(b.selRight) - pad - widest : Number(b.selLeft) + pad + widest
  const arrowNear = rtl ? Number(b.arrowRight) : Number(b.arrowLeft)
  if (!Number.isFinite(nameEnd) || !Number.isFinite(arrowNear)) return NaN
  return rtl ? nameEnd - arrowNear : arrowNear - nameEnd
}

/**
 * Width of `text` in `source`'s computed font, via a hidden probe span.
 * Returns NaN when there is no document to measure in.
 *
 * @param {unknown} source an element whose computed font is the control's
 * @param {unknown} text
 * @returns {number}
 */
export function measureControlText(source, text) {
  const el = source && typeof source === 'object' ? source : null
  const doc = el && el.ownerDocument
  const view = doc && doc.defaultView
  if (!doc || !doc.body || !view || typeof view.getComputedStyle !== 'function') return NaN
  let cs
  try {
    cs = view.getComputedStyle(el)
  } catch {
    return NaN
  }
  if (!cs) return NaN
  const probe = doc.createElement('span')
  probe.setAttribute('data-tenant-measure', '')
  probe.style.position = 'absolute'
  probe.style.left = '0'
  probe.style.top = '0'
  probe.style.visibility = 'hidden'
  probe.style.whiteSpace = 'nowrap'
  probe.style.pointerEvents = 'none'
  probe.style.padding = '0'
  probe.style.margin = '0'
  probe.style.border = '0'
  probe.style.font = cs.font
  probe.style.letterSpacing = cs.letterSpacing
  probe.style.wordSpacing = cs.wordSpacing
  probe.style.textTransform = cs.textTransform
  probe.style.fontKerning = cs.fontKerning
  probe.style.fontFeatureSettings = cs.fontFeatureSettings
  probe.style.fontVariant = cs.fontVariant
  probe.textContent = String(text ?? '')
  doc.body.appendChild(probe)
  let w = NaN
  try {
    w = probe.getBoundingClientRect().width
  } finally {
    probe.remove()
  }
  return w
}
