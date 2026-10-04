// the shell shows exactly ONE topic section (1..1).
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

import { isSectionPage } from './section-strip.mjs'
import { isSearchPage } from './sidebar-tabs.mjs'

/** The live pane (useLiveFeed('pane')): /, /lobby, /search, /?topic=. */
export const LIVE = 'live'
/** The channel / DM topic store: /channel/<name>, /dm/<peer>. */
export const CHANNEL = 'channel'
/** Spec 074 T008: the operator console (stores/operator-pane), the lowest rank. */
export const OPERATOR = 'operator'
/** No topic on screen — the shell is two panes wide. */
export const NONE = 'none'

/**
 * Which single topic section the shell renders for a shell state.
 * The live pane outranks the channel store when both are armed; the layout's
 * watchers make sure that only lasts one tick.
 *
 * @param {{ paneTaskId?: string|null, topicOpen?: boolean, operatorOpen?: boolean }} state
 * @returns {'live'|'channel'|'operator'|'none'}
 */
export function topicSection(state = {}) {
  if (state.paneTaskId) return LIVE
  if (state.topicOpen) return CHANNEL
  if (state.operatorOpen) return OPERATOR
  return NONE
}

/**
 * How many topic sections a shell state may render. The invariant this
 * module exists for: never more than 1, for any state whatsoever.
 *
 * @param {{ paneTaskId?: string|null, topicOpen?: boolean, operatorOpen?: boolean }} state
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

/**
 * Spec 074 T008: the operator console shares the one right-pane slot. The
 * sections that must give way when `opened` opens: opening the console
 * closes either topic store; opening a topic closes the console.
 *
 * @param {'live'|'channel'|'operator'} opened  the section just opened
 * @param {{ paneTaskId?: string|null, topicOpen?: boolean, operatorOpen?: boolean }} state  the state BEFORE it opened
 * @returns {Array<'live'|'channel'|'operator'>}
 */
export function operatorCloses(opened, state = {}) {
  if (opened === OPERATOR) return [state.paneTaskId ? LIVE : '', state.topicOpen ? CHANNEL : ''].filter(Boolean)
  if (opened === LIVE || opened === CHANNEL) return state.operatorOpen ? [OPERATOR] : []
  return []
}

/**
 * t1 6e21c7d8 (owner: "This lin does not work on mobile"): on a phone the
 * open topic pane is level 3, the ONLY panel on screen, and the page sits
 * hidden under it. An in-post link to another page (`/t/<id>`) moved that
 * hidden page and the reader saw nothing change. Whether a route navigation
 * must close the pane so the page it went to shows.
 *
 * Only a forward navigation to another path that names no topic of its own:
 * Back / Forward (`popstate`) restores whatever its entry holds, a
 * `?topic=` write is the pane itself. A desktop shows the page beside the
 * pane, so there it closes only on a section page (`SECTION_PAGES`) or
 * `/search` (spec 078 FR-004), whichever section the pane holds.
 *
 * @param {{ mobile?: boolean, open?: boolean, popstate?: boolean, fromPath?: string, toPath?: string, toQuery?: Record<string, unknown> }} nav
 * @returns {boolean}
 */
export function routeLeavesTopic(nav = {}) {
  if (!nav.open || nav.popstate) return false
  if (!nav.toPath || nav.toPath === nav.fromPath) return false
  if (nav.toQuery && nav.toQuery.topic) return false
  /* spec 078 FR-004 (owner b6f35bf4, 193d95f7): on desktop only a section's
     own page or /search closes the pane; channel to channel / DM keeps it */
  return Boolean(nav.mobile) || isSectionPage(nav.toPath) || isSearchPage(nav.toPath)
}
