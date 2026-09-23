import { createSpoolClient } from '~/utils/spool-client.mjs'
import { apiBaseFor, pickTenant } from '~/utils/tenant.mjs'

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

function readTenant(fallback: string): string {
  if (!import.meta.client) return pickTenant({ fallback })
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
