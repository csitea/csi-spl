// Link the web app manifest, then register the PWA service worker
// (public/sw.js) in a built bundle only. `nuxt dev` runs Vite's HMR worker
// from blob: and must never get a long-lived worker in the way; a failed
// register is logged, never thrown.
//
// Both wait for onNuxtReady (the first page painted, then an idle moment)
// (CLE-77933): a <link rel="manifest"> in the document made Chrome fetch the
// manifest and its 192 px icon while the first screen's chunks were still
// loading - 2 requests / 36.7 KB before the left rail on prd's cold first
// load (do_spl_wui_perf_first_load_net). Install needs neither earlier.
// The worker's stale-shell check and update ask (W9, CLE-77890) load then
// too: utils/pwa-shell-watch.ts, not in the first download (ci_initial_gzip_kb).
import { useBuildWatch } from '~/composables/useBuildWatch'

const MANIFEST_HREF = '/manifest.webmanifest'

export default defineNuxtPlugin(() => {
  // HUM-10: keep Chrome's one install event for Settings' Install button and
  // the "Install app" strip (components/PwaInstallOffer.vue, mounted by
  // app.vue on this event); it fires once the manifest below is linked. Only
  // these lines are in the first download: the rest is utils/pwa-install.mjs,
  // in Settings' lazy chunk, which reads window.__spoolPwa (ci_home_gzip_kb).
  const pwa = ((window as Window & { __spoolPwa?: { ev?: Event, done?: number } }).__spoolPwa ||= {})
  addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); pwa.ev = e })
  addEventListener('appinstalled', () => { pwa.done = 1 })
  const sw = !import.meta.dev && 'serviceWorker' in navigator
  // read in the plugin's own context: onNuxtReady runs outside it
  const ownBuild = sw ? String(useRuntimeConfig().app.buildId || '') : ''
  const watch = sw ? useBuildWatch() : null
  onNuxtReady(() => {
    if (!document.querySelector('link[rel="manifest"]')) {
      const link = document.createElement('link')
      link.rel = 'manifest'
      link.href = MANIFEST_HREF
      document.head.appendChild(link)
    }
    if (import.meta.dev) return
    if (!sw || !watch) return
    navigator.serviceWorker
      .register('/sw.js', { scope: '/', updateViaCache: 'none' })
      .catch((err) => console.warn('[pwa] service worker not registered:', err))
    void import('~/utils/pwa-shell-watch').then((m) => m.watchShellBuild(ownBuild, watch))
  })
})
