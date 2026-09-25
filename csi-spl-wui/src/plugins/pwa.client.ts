// Register the PWA service worker (public/sw.js) in a built bundle only.
// `nuxt dev` runs Vite's HMR worker from blob: and must never get a
// long-lived worker in the way; a failed register is logged, never thrown.
export default defineNuxtPlugin(() => {
  if (import.meta.dev) return
  if (!('serviceWorker' in navigator)) return
  navigator.serviceWorker
    .register('/sw.js', { scope: '/', updateViaCache: 'none' })
    .catch((err) => console.warn('[pwa] service worker not registered:', err))
})
