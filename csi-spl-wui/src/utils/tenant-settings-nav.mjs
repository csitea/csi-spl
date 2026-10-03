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
 * this file.
 */

export const TENANT_SETTINGS_SECTIONS = [
  { id: 'members', label: 'tenant_settings.members', perm: 'members.invite' },
  { id: 'agents', label: 'tenant_settings.agents', perm: 'tenant.settings' },
  { id: 'split', label: 'tenant_settings.split', perm: 'tenant.settings' },
  { id: 'channels', label: 'tenant_settings.channels', perm: 'tenant.settings' },
  { id: 'general', label: 'tenant_settings.general', perm: 'tenant.settings' },
]

/** `me` is normalizeMe()'s shape. The mock build plays an admin. */
export function tenantSettingsSections(me, { mock = false } = {}) {
  if (mock) return TENANT_SETTINGS_SECTIONS.slice()
  const perms = me && Array.isArray(me.permissions) ? me.permissions : []
  return TENANT_SETTINGS_SECTIONS.filter((s) => perms.includes(s.perm))
}

/** Whether the bottom-left icon / the avatar menu row shows. */
export function tenantSettingsVisible(me, opts) {
  return tenantSettingsSections(me, opts).length > 0
}

/**
 * The section id of a route path ('/tenant-settings/general',
 * '/fi/tenant-settings/general/'), '' when not a known section.
 */
export function tenantSettingsSectionOf(path) {
  const m = /\/tenant-settings\/([a-z]+)\/?$/.exec(String(path || '').split(/[?#]/)[0])
  return m && TENANT_SETTINGS_SECTIONS.some((s) => s.id === m[1]) ? m[1] : ''
}
