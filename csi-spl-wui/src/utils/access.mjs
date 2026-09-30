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

import { normalizeChannelOrder } from './channel-order.mjs'

/** 025 §3.2 role ids, in the spec's order (hub internal/rbac RoleIDs). */
export const ROLE_IDS = ['biz_owner', 'product_owner', 'admin', 'developer', 'tester', 'pure_agent', 'biz_customer', 'regular_user']

/**
 * A /v1/view/me body → { humanId, role, tenantOwner, permissions, channelOrder }
 * (permissions null = unrestricted; channelOrder null = never set, SPL-1034).
 */
export function normalizeMe(body) {
  const b = body && typeof body === 'object' ? body : {}
  return {
    humanId: typeof b.human_id === 'string' ? b.human_id : null,
    role: typeof b.role === 'string' && b.role ? b.role : null,
    tenantOwner: b.tenant_owner === true,
    permissions: Array.isArray(b.permissions) ? b.permissions.filter((p) => typeof p === 'string') : null,
    channelOrder: Array.isArray(b.channel_order) ? normalizeChannelOrder(b.channel_order) : null,
    actAs: normalizeActAs(b.act_as),
  }
}

/**
 * specs/054: the act-as state of THIS session. Non-null only when the hub says
 * the session is a temporary clone, so the WUI shows the "Acting as X" banner.
 * { targetHum, targetName, expiresAt } or null.
 */
export function normalizeActAs(a) {
  if (!a || typeof a !== 'object') return null
  const targetHum = typeof a.target_hum === 'string' ? a.target_hum : ''
  if (!targetHum) return null
  return {
    targetHum,
    targetName: (typeof a.target_name === 'string' && a.target_name) ? a.target_name : targetHum,
    expiresAt: typeof a.expires_at === 'string' ? a.expires_at : '',
  }
}

/** The permission to start an act-as clone (hub rbac.MembersImpersonate, specs/054). */
export const MEMBERS_IMPERSONATE = 'members.impersonate'

/** Whether the UI should offer an action needing perm (fails open, see above). */
export function accessAllows(me, perm) {
  if (!me || !Array.isArray(me.permissions)) return true
  return me.permissions.includes(perm)
}

/** The permission that invites and removes tenant members (hub rbac.MembersInvite). */
export const MEMBERS_INVITE = 'members.invite'

/**
 * CLE-77799 (owner topic 1fc29f99: "the admin of a tenant should be able to
 * remove members from the people section"): whether the reader may remove the
 * viewed person from the workspace, for the People card's "Remove from
 * workspace" action. It needs members.invite (fails open like accessAllows —
 * the hub's 403 is the control), and never offers it on the reader themselves
 * or on the tenant's last owner. The hub re-checks role coverage, the self rule
 * and the last-owner rule on the DELETE (internal/hub member removal).
 * @param {{ permissions?: string[] } | null} me normalizeMe() output
 * @param {{ targetId?: string, selfId?: string, targetIsOwner?: boolean, ownerCount?: number }} ctx
 */
export function canRemoveMember(me, { targetId, selfId, targetIsOwner = false, ownerCount = 0 } = {}) {
  const target = String(targetId || '')
  if (!target) return false
  if (selfId && target === String(selfId)) return false
  if (targetIsOwner && Number(ownerCount) <= 1) return false
  return accessAllows(me, MEMBERS_INVITE)
}

/** i18n key of a role's label, '' for none; an unknown (phase-2 custom) role has no key. */
export function roleLabelKey(role) {
  return ROLE_IDS.includes(role) ? `role.${role}` : ''
}
