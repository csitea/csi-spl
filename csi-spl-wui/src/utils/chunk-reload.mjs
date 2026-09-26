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
