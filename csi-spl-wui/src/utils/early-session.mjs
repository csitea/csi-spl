// the session probe, started before the app's plugins have run.
//
// The i18n plugin awaits the locale catalogue (a lazy chunk found only once
// the entry runs), and the route middleware - which sends the probe - runs
// after it: on slow 4G the probe went out ~0.9 s after the entry had loaded
// (prd e2e, n=5). A `pre` plugin starts the probe first; the session store
// takes that answer instead of asking again. Taken once; a store that probes
// later (sign-in, reconnect) asks the hub as before.
//
// P3-03: the document's head script (early-session-script.mjs) starts the
// same GET at parse time, before the entry chunk has even downloaded; the
// plugin hands that parked fetch to the probe (takeParkedSession) instead of
// sending a second one.

import { EARLY_SESSION_KEY } from './early-session-script.mjs'

let early = null

/**
 * The head script's in-flight fetch of `url`, once (it is removed from `win`:
 * a Response body is read only once). Null when there is none, or it asked
 * another address (a stale script must not answer for this build).
 * @param {any} win
 * @param {string} url
 * @returns {Promise<Response> | null}
 */
export function takeParkedSession(win, url) {
  const parked = win && win[EARLY_SESSION_KEY]
  if (!parked) return null
  win[EARLY_SESSION_KEY] = undefined
  if (!parked.p || typeof parked.p.then !== 'function' || parked.u !== url) return null
  return parked.p
}

/**
 * Start `probe()` once per page load; the same promise if already started.
 * Its rejection is swallowed here only so it is not an unhandledrejection
 * while nobody awaits it yet; the caller that takes `early` handles it.
 */
export function startEarlySession(probe) {
  if (!early) {
    const p = probe()
    // The caller awaits `early` and handles a failure; this only marks it handled meanwhile.
    p.catch(() => {})
    early = p
  }
  return early
}

/** The early probe's promise, once; null when none was started or it was taken. */
export function takeEarlySession() {
  const p = early
  early = null
  return p
}
