/**
 * The shell's first two reads (the channel list and the roster), gated on a
 * member session.
 *
 * Both need one: signed out the hub answers 401 view_door to each, so every
 * page load — /login included, where there is nothing to show — put 2×401 in
 * the console (CLE-3374). Nothing goes out until a session probe answers
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
