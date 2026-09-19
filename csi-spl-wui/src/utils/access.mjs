/**
 * Tenant roles and permissions, WUI side (specs/025 FR-006, FR-008).
 * GET /v1/view/me answers { human_id, tenant_id, role, tenant_owner,
 * permissions[] } for the active tenant; a door-off guest gets nulls.
 *
 * Hiding is convenience only: the hub re-checks every write (SEC-RBAC-2).
 * So the WUI fails OPEN here: no answer (old hub, network error) or a null
 * permission list shows everything, and the hub's 403 is the control.
 * Node tests import this file.
 */

/** 025 §3.2 role ids, in the spec's order. */
export const ROLE_IDS = ['biz_owner', 'product_owner', 'admin', 'developer', 'tester', 'pure_agent']

/** A /v1/view/me body → { humanId, role, tenantOwner, permissions } (permissions null = unrestricted). */
export function normalizeMe(body) {
  const b = body && typeof body === 'object' ? body : {}
  return {
    humanId: typeof b.human_id === 'string' ? b.human_id : null,
    role: typeof b.role === 'string' && b.role ? b.role : null,
    tenantOwner: b.tenant_owner === true,
    permissions: Array.isArray(b.permissions) ? b.permissions.filter((p) => typeof p === 'string') : null,
  }
}

/** Whether the UI should offer an action needing perm (fails open, see above). */
export function accessAllows(me, perm) {
  if (!me || !Array.isArray(me.permissions)) return true
  return me.permissions.includes(perm)
}

/** i18n key of a role's label, '' for none; an unknown (phase-2 custom) role has no key. */
export function roleLabelKey(role) {
  return ROLE_IDS.includes(role) ? `role.${role}` : ''
}
