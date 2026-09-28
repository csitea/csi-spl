// the session probe, started before the app's plugins have run.
//
// The i18n plugin awaits the locale catalogue (a lazy chunk found only once
// the entry runs), and the route middleware - which sends the probe - runs
// after it: on slow 4G the probe went out ~0.9 s after the entry had loaded
// (prd e2e, n=5). A `pre` plugin starts the probe first; the session store
// takes that answer instead of asking again. Taken once; a store that probes
// later (sign-in, reconnect) asks the hub as before.

let early = null

/** Start `probe()` once per page load; the same promise if already started. */
export function startEarlySession(probe) {
  if (!early) {
    const p = probe()
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
