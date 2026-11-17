// SPL-5745 (spec 162 F5): which transport-drop codes errorJournal.mjs writes
// mean the network went away. Its own module so the Events page, a lazy
// route, carries it and the initial chunk does not.

/**
 * True for a code that says the network went away (offline, or the tab was
 * asleep), not that the screen failed. `net.unreachable` is not one: a drop
 * while online and awake stays an error.
 * @param {unknown} code
 */
export function isNetworkEventCode(code) {
  return code === 'net.offline' || code === 'net.resumed'
}
