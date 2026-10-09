/**
 * SPL-1006 — an open tab picks up a new deploy, safely.
 *
 * sw.js is network-only on purpose, so nothing ever swapped the bundle of a
 * tab that stays open: on 2026-09-27 prd shipped 64 WUI builds in five hours
 * and a phone PWA kept running whichever one it had opened on. The running
 * build's commit is baked in at `nuxt generate` (runtimeConfig
 * public.buildCommit, from GITHUB_SHA) and compared with the deployed
 * /build.json. This file holds what the first screen and the components need
 * (the constants, normCommit, isNewer); the decisions are in
 * build-watch-rules.mjs, loaded only once the app is ready, with the polling
 * (utils/build-watch-run.ts, plugins/build-watch.client.ts, plugins/pwa)
 * (ci_initial_gzip_kb, c-002 52909f53).
 *
 *   same commit                     -> nothing
 *   newer, nothing being typed      -> reload silently (route kept)
 *   newer, a draft / dialog open    -> the "new version" bar; reload on tap,
 *                                      or by itself once the input is empty
 *   newer, but THIS tab already reloaded for that commit (the guard)
 *                                   -> never again by itself: the bar only
 */

/** How often a visible tab asks (the brief: every 5 minutes). */
export const CHECK_EVERY_MS = 5 * 60_000
/** Focus + visibilitychange can fire together; one fetch per this window. */
export const MIN_GAP_MS = 20_000
/** While the bar waits, how often "is the input empty now?" is asked. */
export const IDLE_POLL_MS = 2_000
/** sessionStorage key: the commit this tab last reloaded itself for. */
export const GUARD_KEY = 'spool.build-reload-for'
/**
 * HUM-10 fb8d109f: a tab hidden at least this long that comes back is a
 * RESUME (the phone was put away, the app reopened), not a keyboard's
 * language picker taking the focus for a moment (HUM-27, no hidden state).
 */
export const RESUME_AFTER_MS = 10_000
/** A full or short hex sha, lower-cased; '' for anything else. */
export function normCommit(c) {
  const s = String(c || '').trim().toLowerCase()
  return /^[0-9a-f]{7,40}$/.test(s) ? s : ''
}

/** True when both are real commits and name different builds. */
export function isNewer(running, live) {
  const r = normCommit(running)
  const l = normCommit(live)
  if (!r || !l) return false
  return !(r.startsWith(l) || l.startsWith(r))
}
