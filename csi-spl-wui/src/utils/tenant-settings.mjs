/**
 * Tenant settings (SPL-1037, specs/046), the section pages' helpers: the
 * body readers, the responder id rule, the error words. The entry gate and
 * the section list are tenant-settings-nav.mjs (the sidebar and the avatar
 * menu load it eagerly; this file only rides with the lazy pages). Node
 * tests import this file.
 */

const str = (v) => (typeof v === 'string' ? v : '')

/** A GET/PATCH /v1/tenant/settings body with safe types. */
export function normalizeTenantSettings(body) {
  const b = body && typeof body === 'object' ? body : {}
  return {
    tenantId: str(b.tenant_id),
    displayName: str(b.display_name),
    defaultLocale: str(b.default_locale),
    responders: (Array.isArray(b.responders) ? b.responders : []).filter((r) => typeof r === 'string' && r),
    maxResponders: Number.isInteger(b.max_responders) && b.max_responders > 0 ? b.max_responders : 20,
  }
}

/** A GET /v1/tenant/channels body → rows with safe types, default channels first, then by name. */
export function normalizeTenantChannels(body) {
  const b = body && typeof body === 'object' ? body : {}
  const rows = (Array.isArray(b.channels) ? b.channels : []).filter((c) => c && str(c.channel)).map((c) => ({
    channel: c.channel,
    name: str(c.name) || c.channel,
    description: str(c.description),
    visibility: c.visibility === 'default' ? 'default' : 'members',
    members: Number(c.members) || 0,
    agents: Number(c.agents) || 0,
    messages: Number(c.messages) || 0,
    noFallback: c.no_fallback === true,
    createdBy: str(c.created_by),
    lastTs: str(c.last_ts),
    archivable: c.archivable === true,
  }))
  rows.sort((a, b) => (a.visibility === b.visibility ? a.name.localeCompare(b.name) : a.visibility === 'default' ? -1 : 1))
  return rows
}

/** An agent id the hub accepts as a responder (CLE-01, GRK-3); never a HUM-*. */
export function validResponderId(s) {
  const v = String(s || '').trim()
  return /^[A-Z]{2,4}-[0-9]+$/.test(v) && !v.startsWith('HUM-')
}

/** Move item i of list by delta (-1 up, +1 down); a new array, unchanged when out of range. */
export function moveItem(list, i, delta) {
  const out = list.slice()
  const j = i + delta
  if (i < 0 || i >= out.length || j < 0 || j >= out.length) return out
  ;[out[i], out[j]] = [out[j], out[i]]
  return out
}

/** The i18n key for a failed tenant-settings call's hub token. */
export function tenantSettingsErrorKey(err) {
  const token = err && typeof err.token === 'string' ? err.token : ''
  const known = ['forbidden', 'bad_setting', 'bad_responder', 'channel_public', 'unknown_channel', 'shared_account', 'bad_name', 'bad_locale', 'last_admin', 'last_owner', 'self']
  return 'tenant_settings.error.' + (known.includes(token) ? token : 'generic')
}
