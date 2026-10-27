/**
 * Tenant settings (SPL-1037, specs/046): the sections and the entry gate.
 * One entry per child route of pages/tenant-settings.vue, in nav order;
 * `label` is a catalogue key and `perm` the permission the hub checks on
 * that section's routes. Kept tiny: the sidebar and the avatar menu import
 * it into the initial chunk.
 *
 * Like tenant-users.mjs this gate does NOT fail open: the entry and a
 * section show only when /v1/view/me listed the permission. The hub
 * re-checks every call (046 §3); hiding is convenience. Node tests import
 * this file through importTs.
 *
 * Fleet load is not a /v1/view/me permission. It is the operator workspace's
 * admin (GET /v1/operator/fleet-load; 403 operator.workspaces hides it).
 * The settings page probes and passes fleetLoad: true only after a 200.
 */

export type TenantSection = { id: string, label: string, perm: string }
export type TenantSectionsOpts = { mock?: boolean, fleetLoad?: boolean }
type TenantMe = { permissions?: string[] | null } | null | undefined

export const TENANT_SETTINGS_SECTIONS: TenantSection[] = [
  { id: 'members', label: 'tenant_settings.members', perm: 'members.invite' },
  { id: 'agents', label: 'tenant_settings.agents', perm: 'tenant.settings' },
  { id: 'split', label: 'tenant_settings.split', perm: 'tenant.settings' },
  { id: 'agent-keys', label: 'tenant_settings.agent_keys_nav', perm: 'vendor_keys.manage' },
  { id: 'takeover', label: 'tenant_settings.takeover', perm: 'tenant.settings' },
  { id: 'channels', label: 'tenant_settings.channels', perm: 'tenant.settings' },
  { id: 'general', label: 'tenant_settings.general', perm: 'tenant.settings' },
  { id: 'hours', label: 'tenant_settings.hours', perm: 'tenant.settings' },
  { id: 'performance', label: 'tenant_settings.performance', perm: 'tenant.settings' },
]

/** Shown only when the fleet-load probe succeeded. Not a me() permission. */
export const FLEET_LOAD_SECTION = { id: 'fleet-load', label: 'tenant_settings.fleet_load' }

/**
 * Sections the mock gates like the hub when an e2e plays a role
 * (spool.mock.me): Agent keys is biz_owner and admin only (spec 159 T7).
 */
const MOCK_GATED = new Set(['agent-keys'])

/**
 * `me` is normalizeMe()'s shape. The mock build plays an admin; a role it
 * plays (me with a permission list) still loses the MOCK_GATED sections it
 * lacks the permission for.
 */
export function tenantSettingsSections(me: TenantMe, opts: TenantSectionsOpts = {}): TenantSection[] {
  const mock = Boolean(opts.mock)
  const perms = me && Array.isArray(me.permissions) ? me.permissions : null
  const base: TenantSection[] = mock
    ? TENANT_SETTINGS_SECTIONS.filter((s) => !perms || !MOCK_GATED.has(s.id) || perms.includes(s.perm))
    : filterByPerm(me)
  if (opts.fleetLoad) base.push(FLEET_LOAD_SECTION as TenantSection)
  return base
}

function filterByPerm(me: TenantMe): TenantSection[] {
  const perms = me && Array.isArray(me.permissions) ? me.permissions : []
  return TENANT_SETTINGS_SECTIONS.filter((s) => perms.includes(s.perm))
}

/** Whether the bottom-left icon / the avatar menu row shows. */
export function tenantSettingsVisible(me: TenantMe, opts?: TenantSectionsOpts): boolean {
  return tenantSettingsSections(me, opts).length > 0
}

/**
 * The section id of a route path ('/tenant-settings/general',
 * '/fi/tenant-settings/fleet-load/'), '' when not a known section.
 */
export function tenantSettingsSectionOf(path: unknown): string {
  const m = /\/tenant-settings\/([a-z]+(?:-[a-z]+)*)\/?$/.exec(String(path || '').split(/[?#]/)[0])
  if (!m) return ''
  const id = m[1]
  if (id === FLEET_LOAD_SECTION.id) return id
  return TENANT_SETTINGS_SECTIONS.some((s) => s.id === id) ? id : ''
}
