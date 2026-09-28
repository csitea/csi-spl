/**
 * The shell's first two reads (the channel list and the roster), gated on a
 * member session.
 *
 * Both need one: signed out the hub answers 401 view_door to each, so every
 * page load — /login included, where there is nothing to show — put 2×401 in
 * the console. Nothing goes out until a session probe answers
 * 'in', and then exactly once for the life of the app: the probe is owned by
 * the shell (ChannelSidebar) and by the login page, and a sign-in flips the
 * same store, so a human who signs in gets the reads without a reload.
 */

/**
 * @param {{ loadChannels: () => unknown, refreshRoster: () => unknown, onError?: (e: unknown) => void }} deps
 */
export function createShellBootstrap(deps) {
  const { loadChannels, refreshRoster, onError } = deps || {}
  let started = false

  /** Both reads, once. Later calls are no-ops and answer the same promise. */
  let inflight = /** @type {Promise<void> | null} */ (null)
  function start() {
    if (started) return inflight
    started = true
    inflight = Promise.all([loadChannels(), refreshRoster()]).then(
      () => undefined,
      (e) => {
        /* the mock tenant still hydrates; a live hub without the WUI routes is expected in M1 */
        if (onError) onError(e)
      },
    )
    return inflight
  }

  /**
   * One session state. 'loading' / 'unknown' / 'out' read nothing at all —
   * 'unknown' is the hub being unreachable (auth-v1 §4), not a signed-in human.
   * @param {string} state
   */
  function onSession(state) {
    return String(state) === 'in' ? start() : null
  }

  return { start, onSession, get started() { return started } }
}

/**
 * Hub WUI socket (003 wui-live-ws / W5). Mock tenant has none; live only with
 * a member session — the same predicate createShellBootstrap.onSession uses
 * for the channel/roster reads, and the same watch shape as spool-live.client.ts.
 * @param {unknown} sessionState
 * @param {boolean} [mock]
 */
export function shouldOpenHubSocket(sessionState, mock = false) {
  if (mock) return false
  return String(sessionState) === 'in'
}

/**
 * is this a visitor we should be showing a way IN, rather than an
 * empty member view? Only a SETTLED 'out' qualifies — 'loading' and 'unknown'
 * must not flash a sign-in notice at a human whose cookie is still being
 * probed, and 'unknown' is an unreachable hub (auth-v1 §4), not a signed-out
 * person. The mock tenant has no sign-in at all, so it is never signed out.
 * @param {unknown} sessionState
 * @param {boolean} [mock]
 */
export function isSignedOutVisitor(sessionState, mock = false) {
  if (mock) return false
  return String(sessionState) === 'out'
}

/**
 * Close the hub socket if one is already up. Must not call ensure() from idle:
 * ensure() constructs and connect()s a client, which is the signed-out leak.
 * @param {{ state?: { value?: unknown }, ensure?: () => { close?: () => void } | null }} live
 */
export function stopHubSocket(live) {
  const s = String((live && live.state && live.state.value) || '')
  if (s === 'idle' || s === 'mock' || s === 'closed' || s === 'no_base' || !s) return
  const client = live.ensure && live.ensure()
  if (client && typeof client.close === 'function') client.close()
}

/**
 * Open or resume the hub socket. ensure() connect()s on first create; a
 * previously closed client needs an explicit connect() to come back.
 * @param {{ ensure?: () => { state?: string, connect?: () => void } | null }} live
 */
export function startHubSocket(live) {
  const client = live && live.ensure ? live.ensure() : null
  if (client && (client.state === 'closed' || client.state === 'idle') && typeof client.connect === 'function') {
    client.connect()
  }
  return client
}
