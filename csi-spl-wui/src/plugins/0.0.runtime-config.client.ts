// Spec 072 A3: the env values of this page come from the served /config.json
// (utils/runtime-config.mjs), merged into useRuntimeConfig().public BEFORE any
// other plugin reads them: the early session probe (0.boot-early), the tenant
// host hop, the live socket. The head script already started the fetch at
// parse time; this adopts it, so the wait is whatever is left of one small
// same-origin request. No file (lde, an older deploy) keeps the baked config;
// no api base at all (a bundle built with no NUXT_PUBLIC_API_BASE, the compose
// stack) means the page's own origin. A mock build has no hub and asks nothing.
import { applyRuntimeConfig, defaultApiBase, takeParkedConfig } from '~/utils/runtime-config.mjs'

export default defineNuxtPlugin({
  name: 'spool:runtime-config',
  // before every `enforce: 'pre'` plugin (-20), 0.boot-early among them
  order: -30,
  async setup() {
    if (!import.meta.client) return
    const pub = useRuntimeConfig().public as Record<string, unknown>
    if (String(pub.useMock) !== '0') return
    const raw = await takeParkedConfig(window, window.fetch?.bind(window))
    const { rejected } = applyRuntimeConfig(pub, raw)
    if (rejected.length) console.warn(`[spool] /config.json: ignored ${rejected.join(', ')} (not the expected shape)`)
    defaultApiBase(pub, window.location.origin)
  },
})
