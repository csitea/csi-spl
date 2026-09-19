/**
 * Hub origin + tenant choice (specs/026: the hub takes the tenant from the
 * signed-in session, not from the Host).
 *
 * dev / prd: NUXT_PUBLIC_API_BASE is the single api host (https://api.<fqdn>);
 * the session's active tenant decides what is read. lde (and the transition):
 * a template holding {tenant} still reads from <tenant>.<fqdn>. The tenant
 * picked here (?tenant=, then the remembered one, then NUXT_PUBLIC_TENANT) is
 * what sign-in binds the session to.
 */

// mirror of internal/msg/msg.go reservedTenants (006 FR-016); the hub is the authority
export const RESERVED_TENANTS = new Set([
  'dev', 'prd', 'lde', 'stg', 'tst',
  'www', 'api', 'app', 'hub', 'wui',
  'admin', 'auth', 'login', 'mail',
  'status', 'docs', 'help', 'support',
])

const TENANT_RE = /^[a-z0-9][a-z0-9-]{0,31}$/

export function validTenant(s) {
  const t = String(s || '')
  return TENANT_RE.test(t) && !RESERVED_TENANTS.has(t)
}

/** First valid of: query, stored, fallback. '' when none. */
export function pickTenant({ query, stored, fallback } = {}) {
  for (const c of [query, stored, fallback]) {
    const t = String(c || '').trim().toLowerCase()
    if (validTenant(t)) return t
  }
  return ''
}

/**
 * The hub origin for tenant reads.
 * - template with {tenant} (lde, legacy tenant hosts): substituted; no tenant
 *   → { base: '', error: 'no_tenant' }; a reserved label substituted is the
 *   API host by accident → { error: 'api_host' }
 * - fixed origin: used as-is; the api host (api.<fqdn>) is the normal case
 *   since specs/026
 */
export function apiBaseFor(template, tenant) {
  const tpl = String(template || '').replace(/\/+$/, '')
  if (!tpl) return { base: '', error: 'no_base' }
  const templated = tpl.includes('{tenant}')
  let base = tpl
  if (templated) {
    if (!validTenant(tenant)) return { base: '', error: 'no_tenant' }
    base = tpl.split('{tenant}').join(tenant)
  }
  let host = ''
  try {
    host = new URL(base).hostname
  } catch {
    return { base: '', error: 'bad_base' }
  }
  const first = host.split('.')[0]
  if (templated && host.includes('.') && RESERVED_TENANTS.has(first)) return { base: '', error: 'api_host' }
  return { base, error: '' }
}
