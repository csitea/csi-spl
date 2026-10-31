// chunk-reload.client.ts - a stale tab after a deploy reloads once into the
// new build instead of breaking (see utils/chunk-reload.mjs).
// Client-only by file suffix: Nuxt loads a *.client.ts plugin only in the
// client bundle, so an import.meta.client guard here is dead.
import { armChunkReloadDecision, markChunkReloaded, onPreloadError, onUnhandledChunkError, shouldReload } from '~/utils/chunk-reload'

const KEY = 'spool.chunk-reload-at'

function readLast(): number {
  try { return Number(sessionStorage.getItem(KEY) || 0) } catch { return 0 /* storage blocked */ }
}

export default defineNuxtPlugin((nuxtApp) => {
  function reloadOnce() {
    const last = readLast()
    /* 080 T006: offline, a failed chunk is the network, not a stale build -
       and a reload with no network blanks the tab, with any send held for
       the network in it. Never then. */
    if (navigator.onLine === false || !shouldReload(last)) return
    try { sessionStorage.setItem(KEY, String(Date.now())) } catch { /* storage blocked */ }
    markChunkReloaded()
    window.location.reload()
  }
  // SPL-4525: the error journal asks this whether a chunk failure is an app
  // update. Until reloadOnce reloads, only it writes KEY, so the value read
  // here is the one reloadOnce would read now.
  const atLoad = readLast()
  armChunkReloadDecision(() => navigator.onLine !== false && shouldReload(atLoad))
  // Vite: a dynamic import's preload failed (lazy components, route chunks).
  // Never cancel a JS failure: Vite would then resolve the import to undefined.
  window.addEventListener('vite:preloadError', (ev) => onPreloadError(ev, reloadOnce))
  // Nuxt: a chunk failed while rendering / navigating
  nuxtApp.hook('app:chunkError', () => reloadOnce())
  // Anything else that surfaces as an unhandled chunk failure
  window.addEventListener('unhandledrejection', (ev) => onUnhandledChunkError(ev, reloadOnce))
})
