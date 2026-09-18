import { createSpoolClient } from '~/utils/spool-client.mjs'

let client: ReturnType<typeof createSpoolClient> | null = null

export function useSpoolApi() {
  if (client) return client
  const config = useRuntimeConfig()
  client = createSpoolClient({
    base: String(config.public.apiBase || ''),
    mock: String(config.public.useMock) !== '0',
  })
  return client
}
