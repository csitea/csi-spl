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
const MANIFEST_HREF = '/manifest.webmanifest'

export default defineNuxtPlugin(() => {
  onNuxtReady(() => {
    if (!document.querySelector('link[rel="manifest"]')) {
      const link = document.createElement('link')
      link.rel = 'manifest'
      link.href = MANIFEST_HREF
      document.head.appendChild(link)
    }
    if (import.meta.dev) return
    if (!('serviceWorker' in navigator)) return
    navigator.serviceWorker
      .register('/sw.js', { scope: '/', updateViaCache: 'none' })
      .catch((err) => console.warn('[pwa] service worker not registered:', err))
  })
  if (import.meta.dev) return
  if (!('serviceWorker' in navigator)) return
  // CLE-77890: a phone keeps one tab alive for days and a single-page app
  // never navigates, so the browser would not look for a new worker. Ask
  // whenever the tab comes back (at most once a minute); the new one
  // activates at once (skipWaiting + clients.claim).
  let checkedAt = 0
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible' || Date.now() - checkedAt < 60000) return
    checkedAt = Date.now()
    void navigator.serviceWorker.getRegistration()
      .then((reg) => reg && reg.update())
      .catch(() => {})
  })
})
