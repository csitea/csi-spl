// CLE-3429 — the shell shows exactly ONE topic section (1..1).
//
// Why this module exists: the shell has two topic panes driven by two
// independent pinia stores — LiveTopicPane off useLiveFeed('pane') (fed by
// /, /lobby, /search and the /?topic= deep link) and TopicPane off the
// topic store (fed by the /channel and /dm feeds through MessageFeed).
// Neither store is reset on a route change, so any path that armed one while
// the other was still armed rendered BOTH asides at once: open a topic on
// /channel/lobby, walk to /lobby, open one there — two topic sections, and
// they stayed for every later route.
//
// The decision now lives here, in one pure function, and layouts/default.vue
// renders that one section as a v-if / v-else chain. That is the structural
// half of the guarantee: the two components can never both sit in the tree,
// on any route, theme or width. The layout's exclusivity watchers are the
// other half — they keep the state honest so the section the reader opened
// LAST is the one that wins.

/** The live pane (useLiveFeed('pane')): /, /lobby, /search, /?topic=. */
export const LIVE = 'live'
/** The channel / DM topic store: /channel/<name>, /dm/<peer>. */
export const CHANNEL = 'channel'
/** No topic on screen — the shell is two panes wide. */
export const NONE = 'none'

/**
 * Which single topic section the shell renders for a shell state.
 * The live pane outranks the channel store when both are armed; the layout's
 * watchers make sure that only lasts one tick.
 *
 * @param {{ paneTaskId?: string|null, topicOpen?: boolean }} state
 * @returns {'live'|'channel'|'none'}
 */
export function topicSection(state = {}) {
  if (state.paneTaskId) return LIVE
  if (state.topicOpen) return CHANNEL
  return NONE
}

/**
 * How many topic sections a shell state may render. The invariant this
 * module exists for: never more than 1, for any state whatsoever.
 *
 * @param {{ paneTaskId?: string|null, topicOpen?: boolean }} state
 * @returns {0|1}
 */
export function sectionCount(state = {}) {
  return topicSection(state) === NONE ? 0 : 1
}

/**
 * Arming one section disarms the other. Returns the section the caller must
 * close, or '' when there is nothing to close.
 *
 * @param {'live'|'channel'} opened  the section just opened
 * @param {{ paneTaskId?: string|null, topicOpen?: boolean }} state  the state BEFORE it opened
 * @returns {'live'|'channel'|''}
 */
export function closes(opened, state = {}) {
  if (opened === LIVE) return state.topicOpen ? CHANNEL : ''
  if (opened === CHANNEL) return state.paneTaskId ? LIVE : ''
  return ''
}
