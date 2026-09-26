import { createSpoolClient } from '~/utils/spool-client.mjs'
import { apiBaseFor, pickTenant } from '~/utils/tenant.mjs'
import { pageTenant } from '~/utils/tenant-host-core.mjs'

/** view-v1 §2: the view token lives in memory / sessionStorage, never localStorage or a URL. */
export const VIEW_TOKEN_KEY = 'spool.view_token'
/** The tenant chosen via ?tenant= is remembered for the tab (not a secret). */
export const TENANT_KEY = 'spool.tenant'

let client: ReturnType<typeof createSpoolClient> | null = null

function readToken(): string {
  if (!import.meta.client) return ''
  try {
    return sessionStorage.getItem(VIEW_TOKEN_KEY) || ''
  } catch {
    return ''
  }
}

/** SPL-959: with tenant hosts on, the page's host names the tenant ('' = not one). */
export function hostTenant(): string {
  if (!import.meta.client) return ''
  const pub = useRuntimeConfig().public
  if (String(pub.tenantHosts || '0') !== '1') return ''
  return pageTenant(window.location.hostname, String(pub.siteUrl || ''), String(pub.tenant || ''))
}

/**
 * SPL-959: the URL of path on tenant's host, '' when tenant hosts are off
 * (the caller then switches the session's tenant, specs/026 §6). Loaded on
 * the click: the initial chunk is at its 027 budget.
 */
export async function tenantHostUrl(tenant: string, path: string): Promise<string> {
  if (!hostTenant()) return ''
  const pub = useRuntimeConfig().public
  const { tenantUrl } = await import('~/utils/tenant-host.mjs')
  return tenantUrl(tenant, String(pub.siteUrl || ''), String(pub.tenant || ''), path)
}

function readTenant(fallback: string): string {
  if (!import.meta.client) return pickTenant({ fallback })
  const host = hostTenant()
  if (host) return host
  let query = ''
  let stored = ''
  try {
    query = new URLSearchParams(window.location.search).get('tenant') || ''
    stored = sessionStorage.getItem(TENANT_KEY) || ''
  } catch {
    /* no storage: query / fallback only */
  }
  const t = pickTenant({ query, stored, fallback })
  try {
    if (t && t !== fallback) sessionStorage.setItem(TENANT_KEY, t)
  } catch {
    /* memory only */
  }
  return t
}

/**
 * Hub origin for tenant reads comes from apiBaseFor. A fixed api host is
 * used as-is (the normal case since specs/026). A {tenant} template is
 * substituted only for lde.
 */
export function useSpoolApi() {
  if (client) return client
  const config = useRuntimeConfig()
  const tenant = readTenant(String(config.public.tenant || ''))
  const { base, error } = apiBaseFor(String(config.public.apiBase || ''), tenant)
  client = createSpoolClient({
    base,
    mock: String(config.public.useMock) !== '0',
    token: readToken(),
    tenant,
    configError: error,
  })
  return client
}

export function setViewToken(token: string) {
  const t = token.trim()
  useSpoolApi().setToken(t)
  if (!import.meta.client) return
  try {
    if (t) sessionStorage.setItem(VIEW_TOKEN_KEY, t)
    else sessionStorage.removeItem(VIEW_TOKEN_KEY)
  } catch {
    /* private mode: memory only */
  }
}
