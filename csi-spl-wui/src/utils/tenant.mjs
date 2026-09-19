/**
 * Tenant host resolution (003 contracts/http-v1.md: tenant = request Host;
 * reserved labels are the API host and never a tenant, cfe5a9b).
 *
 * The WUI reads tenant data from <tenant>.<fqdn> (lde: <tenant>.localhost),
 * never from api.<fqdn> / dev.api.<fqdn>. NUXT_PUBLIC_API_BASE is a template
 * holding {tenant}; the tenant comes from ?tenant=, then the remembered one,
 * then NUXT_PUBLIC_TENANT. The WUI's own host is not used: it is served from
 * Hosting (web.app / the env fqdn), not from a tenant host.
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
 * - template with {tenant}: substituted; no tenant → { base: '', error: 'no_tenant' }
 * - fixed origin (legacy): used as-is
 * Either way, a first host label that is reserved (api., dev., www. …) is the
 * API host, where every tenant route is 404 → { error: 'api_host' }.
 */
export function apiBaseFor(template, tenant) {
  const tpl = String(template || '').replace(/\/+$/, '')
  if (!tpl) return { base: '', error: 'no_base' }
  let base = tpl
  if (tpl.includes('{tenant}')) {
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
  if (host.includes('.') && RESERVED_TENANTS.has(first)) return { base: '', error: 'api_host' }
  return { base, error: '' }
}
