// CLE-3429 — the shell shows exactly ONE thread section (1..1).
//
// Why this module exists: the shell has two thread panes driven by two
// independent pinia stores — LiveThreadPane off useLiveFeed('pane') (fed by
// /, /lobby, /search and the /?thread= deep link) and ThreadPane off the
// thread store (fed by the /channel and /dm feeds through MessageFeed).
// Neither store is reset on a route change, so any path that armed one while
// the other was still armed rendered BOTH asides at once: open a thread on
// /channel/lobby, walk to /lobby, open one there — two thread sections, and
// they stayed for every later route.
//
// The decision now lives here, in one pure function, and layouts/default.vue
// renders that one section as a v-if / v-else chain. That is the structural
// half of the guarantee: the two components can never both sit in the tree,
// on any route, theme or width. The layout's exclusivity watchers are the
// other half — they keep the state honest so the section the reader opened
// LAST is the one that wins.

/** The live pane (useLiveFeed('pane')): /, /lobby, /search, /?thread=. */
export const LIVE = 'live'
/** The channel / DM thread store: /channel/<name>, /dm/<peer>. */
export const CHANNEL = 'channel'
/** No thread on screen — the shell is two panes wide. */
export const NONE = 'none'

/**
 * Which single thread section the shell renders for a shell state.
 * The live pane outranks the channel store when both are armed; the layout's
 * watchers make sure that only lasts one tick.
 *
 * @param {{ paneTaskId?: string|null, threadOpen?: boolean }} state
 * @returns {'live'|'channel'|'none'}
 */
export function threadSection(state = {}) {
  if (state.paneTaskId) return LIVE
  if (state.threadOpen) return CHANNEL
  return NONE
}

/**
 * How many thread sections a shell state may render. The invariant this
 * module exists for: never more than 1, for any state whatsoever.
 *
 * @param {{ paneTaskId?: string|null, threadOpen?: boolean }} state
 * @returns {0|1}
 */
export function sectionCount(state = {}) {
  return threadSection(state) === NONE ? 0 : 1
}

/**
 * Arming one section disarms the other. Returns the section the caller must
 * close, or '' when there is nothing to close.
 *
 * @param {'live'|'channel'} opened  the section just opened
 * @param {{ paneTaskId?: string|null, threadOpen?: boolean }} state  the state BEFORE it opened
 * @returns {'live'|'channel'|''}
 */
export function closes(opened, state = {}) {
  if (opened === LIVE) return state.threadOpen ? CHANNEL : ''
  if (opened === CHANNEL) return state.paneTaskId ? LIVE : ''
  return ''
}
