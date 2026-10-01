// Register the PWA service worker (public/sw.js) in a built bundle only.
// `nuxt dev` runs Vite's HMR worker from blob: and must never get a
// long-lived worker in the way; a failed register is logged, never thrown.
export default defineNuxtPlugin(() => {
  if (import.meta.dev) return
  if (!('serviceWorker' in navigator)) return
  navigator.serviceWorker
    .register('/sw.js', { scope: '/', updateViaCache: 'none' })
    .catch((err) => console.warn('[pwa] service worker not registered:', err))
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
