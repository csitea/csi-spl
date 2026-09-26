// chunk-reload.client.ts - a stale tab after a deploy reloads once into the
// new build instead of breaking (see utils/chunk-reload.mjs).
import { isChunkLoadError, shouldReload } from '~/utils/chunk-reload.mjs'

const KEY = 'spool.chunk-reload-at'

export default defineNuxtPlugin((nuxtApp) => {
  if (!import.meta.client) return
  function reloadOnce() {
    let last = 0
    try { last = Number(sessionStorage.getItem(KEY) || 0) } catch { /* storage blocked */ }
    if (!shouldReload(last)) return
    try { sessionStorage.setItem(KEY, String(Date.now())) } catch { /* storage blocked */ }
    window.location.reload()
  }
  // Vite: a dynamic import's preload failed (lazy components, route chunks)
  window.addEventListener('vite:preloadError', (ev) => {
    ev.preventDefault()
    reloadOnce()
  })
  // Nuxt: a chunk failed while rendering / navigating
  nuxtApp.hook('app:chunkError', () => reloadOnce())
  // Anything else that surfaces as an unhandled chunk failure
  window.addEventListener('unhandledrejection', (ev) => {
    if (isChunkLoadError(ev.reason)) reloadOnce()
  })
})
