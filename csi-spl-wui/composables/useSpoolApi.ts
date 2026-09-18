import { createSpoolClient } from '~/utils/spool-client.mjs'

/** view-v1 §2: the view token lives in memory / sessionStorage, never localStorage or a URL. */
export const VIEW_TOKEN_KEY = 'spool.view_token'

let client: ReturnType<typeof createSpoolClient> | null = null

function readToken(): string {
  if (!import.meta.client) return ''
  try {
    return sessionStorage.getItem(VIEW_TOKEN_KEY) || ''
  } catch {
    return ''
  }
}

export function useSpoolApi() {
  if (client) return client
  const config = useRuntimeConfig()
  client = createSpoolClient({
    base: String(config.public.apiBase || ''),
    mock: String(config.public.useMock) !== '0',
    token: readToken(),
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
