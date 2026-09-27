/*
 * SPL-989 (epic SPL-988, the mobile revamp): the pure half of
 * composables/useMobileStack.ts. No Vue, no window: every rule the phone
 * shell follows is a function of its inputs here, so node:test proves it.
 * Names carry "mobile" because Nuxt auto-imports every utils export.
 *
 * The owner's navigation model (fixed): at <= MOBILE_STACK_MAX_PX exactly ONE
 * of the desktop's three panels is on screen.
 *   level 1 = the LEFT panel (the section chooser + the chosen section's list)
 *   level 2 = the MIDDLE panel (a channel / DM / lobby feed, a page's list)
 *   level 3 = the RIGHT panel (the open topic / thread)
 * A tap pushes, Back (the chevron, a swipe right, browser Back) pops one level.
 */

/** Widest viewport that gets the one-panel shell. 821 px and up is desktop. */
export const MOBILE_STACK_MAX_PX = 820
export const MOBILE_STACK_QUERY = `(max-width: ${MOBILE_STACK_MAX_PX}px)`

/** The key this shell adds to history.state (vue-router keeps unknown keys). */
export const MOBILE_LEVEL_KEY = 'splLevel'
/** Set on an entry the shell pushed on top of an in-app entry: Back = history.back(). */
export const MOBILE_BELOW_KEY = 'splBelow'

/** A swipe that pops: this far right, and mostly horizontal. */
export const MOBILE_SWIPE_MIN_DX = 64
export const MOBILE_SWIPE_MAX_DY = 48
/** A swipe must start in the left half of the screen (not a text selection). */
export const MOBILE_SWIPE_EDGE_RATIO = 0.5

/**
 * Which level is on screen. A topic open anywhere is level 3; otherwise the
 * reader is either on the left panel (home) or the middle one.
 * @param {{ home: boolean, topicOpen: boolean }} s
 * @returns {1|2|3}
 */
export function mobileLevelOf(s) {
  if (s.topicOpen) return 3
  return s.home ? 1 : 2
}

/** `/`, `/fi`, `/bg/` ... : the index page under any locale prefix. */
export function isMobileFrontDoor(path) {
  const p = String(path || '/').replace(/\/+$/, '')
  return p === '' || /^\/[a-z]{2}(-[A-Za-z]{2,4})?$/.test(p)
}

/**
 * The level a freshly loaded URL opens at. `/` (any locale prefix) with no
 * topic in the query is the app's front door, so it opens on the left panel;
 * any other path is a deep link to the middle panel, ?topic= / ?in= to the
 * right one.
 * @returns {1|2|3}
 */
export function mobileInitialLevel(path, query) {
  const q = query || {}
  if (q.topic || q.in) return 3
  return isMobileFrontDoor(path) ? 1 : 2
}

/**
 * The level a history entry was tagged with, or null for an entry the shell
 * has not seen (a fresh router push, the first load).
 * @returns {1|2|3|null}
 */
export function mobileTaggedLevel(state) {
  const v = state && typeof state === 'object' ? state[MOBILE_LEVEL_KEY] : null
  return v === 1 || v === 2 || v === 3 ? v : null
}

/** True when the entry sits on top of another in-app entry, so Back is history.back(). */
export function mobileHasBelow(state) {
  const v = state && typeof state === 'object' ? state[MOBILE_BELOW_KEY] : null
  return v === 1 || v === 2 || v === 3
}

/** history.state with this shell's tags merged in; the router's own keys untouched. */
export function mobileTagState(state, level, below) {
  const base = state && typeof state === 'object' ? { ...state } : {}
  base[MOBILE_LEVEL_KEY] = level
  if (below) base[MOBILE_BELOW_KEY] = below
  else if (below === 0) delete base[MOBILE_BELOW_KEY]
  return base
}

/**
 * What the shell does with history when the level on screen changes and the
 * change did NOT come from a popstate.
 *   'tag'  - the entry is fresh (a router push, the first load) or the level
 *            went DOWN on it: write the level onto it (replaceState)
 *   'push' - the level went UP on the same entry (a topic opened, a list row
 *            tapped for the page already behind it): add an entry, so Back
 *            comes down again
 *   'none' - nothing to record
 * @param {1|2|3|null} tagged what the current entry says
 * @param {1|2|3} next the level now on screen
 * @returns {'tag'|'push'|'none'}
 */
export function mobileHistoryStep(tagged, next) {
  if (tagged === null) return 'tag'
  if (tagged === next) return 'none'
  return next > tagged ? 'push' : 'tag'
}

/**
 * One touch gesture: does it pop a level? A right swipe that starts in the
 * left half of the screen, travels MOBILE_SWIPE_MIN_DX and stays mostly
 * horizontal. In rtl the mirror image pops.
 * @param {{ x0: number, y0: number, x1: number, y1: number, width: number, rtl?: boolean }} g
 */
export function isMobileBackSwipe(g) {
  if (!(g.width > 0)) return false
  const dx = g.rtl ? g.x0 - g.x1 : g.x1 - g.x0
  const dy = Math.abs(g.y1 - g.y0)
  const start = g.rtl ? g.width - g.x0 : g.x0
  if (start > g.width * MOBILE_SWIPE_EDGE_RATIO) return false
  return dx >= MOBILE_SWIPE_MIN_DX && dy <= MOBILE_SWIPE_MAX_DY && dx > dy * 1.5
}
