/**
 * A tab opened before a deploy asks for /_nuxt/<hash>.js files the new build
 * no longer has: "Failed to fetch dynamically imported module" (seen in the
 * owner's event log, 2026-09-26). The only cure is the new build, so the page
 * reloads - ONCE per window: a second failure within RELOAD_GUARD_MS means the
 * reload did not help (an outage, not a stale tab) and we must not loop.
 */
export const RELOAD_GUARD_MS = 10_000

/** True when this looks like a missing build chunk. */
export function isChunkLoadError(err) {
  const msg = String((err && (err.message || err.reason?.message)) || err || '')
  return /Failed to fetch dynamically imported module|Importing a module script failed|error loading dynamically imported module|Loading chunk [\w-]+ failed|ChunkLoadError/i.test(msg)
}

/** Reload now? `last` is the epoch ms of the previous chunk reload, or 0. */
export function shouldReload(last, now = Date.now()) {
  const l = Number(last) || 0
  return !(l > 0 && now - l >= 0 && now - l < RELOAD_GUARD_MS)
}

/**
 * The vite:preloadError listener. Vite's preload helper reads preventDefault()
 * as "this import is handled": `baseModule().catch(handle)` then RESOLVES to
 * undefined, and every `import(x).then((m) => m.fn())` becomes a TypeError
 * page error ("reading 'useMobileStack'", "Cannot destructure property
 * 'bindShipperToJournal' of 'undefined'") instead of a chunk failure. So only
 * a CSS preload failure is cancelled, because the module itself still loads
 * (Nuxt does the same). A JS failure lets the import REJECT: the caller's
 * catch takes it, or onUnhandledChunkError below does. Either way the page
 * reloads once.
 */
export function onPreloadError(ev, reload) {
  const msg = String(ev?.payload?.message || '')
  if (/Unable to preload CSS/.test(msg)) ev.preventDefault()
  reload()
}

/**
 * The unhandledrejection listener. A chunk failure that no caller caught
 * reloads once. It is marked handled so it is not also reported as an
 * uncaught page error. Any other rejection is left alone.
 */
export function onUnhandledChunkError(ev, reload) {
  if (!isChunkLoadError(ev?.reason)) return
  ev.preventDefault()
  reload()
}
