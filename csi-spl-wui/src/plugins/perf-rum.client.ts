// perf-rum.client.ts — spec 066 L5: start the real-user timing collector.
//
// Off unless cnf turns it on (perf.rum_enabled -> NUXT_PUBLIC_PERF_RUM=1, wf30).
// The collector (utils/perf-rum.mjs) is NOT in the initial chunk: it is
// imported after onNuxtReady, and a failed import leaves the app exactly as
// with RUM off (spec 4.0). Batches wait in its buffer until the session store
// says 'in' (the ingest needs a member session); the mock tenant has none.
//
// Client-only: there is no browser timing on the server.
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'

export default defineNuxtPlugin(() => {
  const pub = useRuntimeConfig().public
  if (String(pub.perfRum) !== '1') return
  const session = useSessionStore()
  onNuxtReady(() => {
    const api = useSpoolApi()
    if (!api.base) return
    void import('~/utils/perf-rum.mjs').then(({ startPerfRum }) => {
      startPerfRum({
        url: `${api.base}/v1/perf/samples`,
        credentials: api.credentials,
        build: String(pub.appVersion || ''),
        sampleRate: String(pub.perfSampleRate ?? ''),
        ready: () => session.state === 'in',
      })
    }).catch(() => { /* RUM off for this tab */ })
  })
})
