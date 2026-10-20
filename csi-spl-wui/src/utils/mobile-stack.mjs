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
 * Deep links open where they point (`/channel/x` at 2, `?topic=` at 3) and
 * Back still walks 3 -> 2 -> 1 inside the app. 600..820 px tablets get the
 * same ONE panel (decision: a 600 px topic beside a 220 px feed reads worse
 * than two full screens), plus a 60 px channel strip beside levels 2 and 3
 * (SPL-2145, TabletStrip). Above 820 px the shell writes no history entry.
 */

/** Widest viewport that gets the one-panel shell. 821 px and up is desktop. */
export const MOBILE_STACK_MAX_PX = 820
export const MOBILE_STACK_QUERY = `(max-width: ${MOBILE_STACK_MAX_PX}px)`

/**
 * SPL-2145 (UI review suggestion 3): a tablet, 600..820 px, keeps a narrow
 * strip of the channels (components/TabletStrip.vue) beside the one panel of
 * levels 2 and 3; a phone under MOBILE_TABLET_MIN_PX keeps one panel alone.
 */
export const MOBILE_TABLET_MIN_PX = 600
export const MOBILE_TABLET_QUERY = `(min-width: ${MOBILE_TABLET_MIN_PX}px) and (max-width: ${MOBILE_STACK_MAX_PX}px)`

/**
 * The tablet strip's label for a channel: the first letter of each of its
 * first two words ("dev-ops" -> "DO"), else its first two letters ("lobby"
 * -> "LO"). Letters and digits of any script; '#' when the name has none.
 */
export function mobileChannelInitials(name) {
  const words = String(name || '').split(/[^\p{L}\p{N}]+/u).filter(Boolean)
  if (!words.length) return '#'
  const pick = words.length > 1 ? [...words[0]][0] + [...words[1]][0] : [...words[0]].slice(0, 2).join('')
  return pick.toLocaleUpperCase()
}

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
 * c78fb3ec (owner: "the back button on both the bottom and top bars does not
 * work" ... "one has to close the app"): an entry tagged below level 3 must
 * not name a topic in its URL. A link to `?topic=` (router.push) makes a fresh
 * entry that router.afterEach tags 2 before the topic opens; the level-3 push
 * on top of it copied that URL, so Back landed on a level-2 entry that opened
 * the topic again - level 3, another push, the same entry on the next Back.
 * Returns the URL without topic/in for an entry tagged 1 or 2 that has them,
 * else null (level 3, an untagged entry, nothing to drop).
 * @param {string} href the entry's URL
 * @param {1|2|3|null} tagged the level the entry says (or will say)
 * @returns {string|null}
 */
export function mobileStaleTopicUrl(href, tagged) {
  if (tagged !== 1 && tagged !== 2) return null
  let u
  try { u = new URL(href) } catch { return null }
  if (!u.searchParams.has('topic') && !u.searchParams.has('in')) return null
  u.searchParams.delete('topic')
  u.searchParams.delete('in')
  return u.pathname + u.search + u.hash
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
 * CLE-77882: a message opened IN PLACE from a list (Flow, Search) is one
 * history entry, not two. The route push makes a fresh entry at level 2 and
 * the topic opening on it would push level 3 on top, so Back first closed
 * the thread onto a bare channel and only a second Back reached the list
 * (owner: "Back returns to the list"). While an open-in-place is pending,
 * that 'push' to 3 becomes a 'tag': the entry IS the opened message, and the
 * entry under it is the list.
 * @param {'tag'|'push'|'none'} step mobileHistoryStep's answer
 * @param {1|2|3} next the level now on screen
 * @param {boolean} inPlace an open-in-place is pending
 * @returns {'tag'|'push'|'none'}
 */
export function mobileInPlaceStep(step, next, inPlace) {
  return inPlace && step === 'push' && next === 3 ? 'tag' : step
}

/**
 * The level moved to `next` without a popstate: what to record. mobileHistoryStep,
 * folded by mobileInPlaceStep while an open-in-place is pending; that pending
 * open is used up (`clearInPlace`) once the thread is on screen.
 * @param {1|2|3|null} tagged what the current entry says
 * @param {1|2|3} next the level now on screen
 * @param {boolean} inPlace an open-in-place is pending
 * @returns {{ step: 'tag'|'push'|'none', clearInPlace: boolean }}
 */
export function mobileRecordStep(tagged, next, inPlace) {
  return { step: mobileInPlaceStep(mobileHistoryStep(tagged, next), next, inPlace), clearInPlace: inPlace && next === 3 }
}

/**
 * The level went UP on the same entry: the entry to push, so Back comes down
 * again. c78fb3ec: the entry left below must not keep the topic's URL (a link
 * to ?topic= wrote it there before the topic opened), or Back onto it opens
 * the topic again - stuck on level 3. It keeps its page (`under`, written onto
 * it first); the new entry takes the topic URL (`url`).
 * @param {string} href the current URL
 * @param {unknown} state the current history.state
 * @param {1|2|3} next the level now on screen
 * @param {1|2|3|null} tagged what the current entry says
 * @returns {{ under: string|null, state: Record<string, unknown>, url: string|undefined }}
 */
export function mobilePushPlan(href, state, next, tagged) {
  const under = mobileStaleTopicUrl(href, tagged)
  return { under, state: mobileTagState(mobileOverlayState(state, null), next, tagged ?? 1), url: under ? href : undefined }
}

/**
 * Back by the chevron or a swipe (pop()):
 *   'overlay' - SPL-994: the top overlay goes first (its entry is stepped over)
 *   'history' - an entry of ours is below: history.back()
 *   'down'    - a deep link, nothing of ours below: step down a level in place
 *   'none'    - not a phone, level 1 already, or (t1 3b8891e0) a page level
 *               above the deep link stepped up itself (`up()` returned true)
 * `up` is asked last, and only on level 2 with nothing below.
 * @param {{ mobile: boolean, overlays: number, level: 1|2|3, hasBelow: boolean, up: () => boolean }} s
 * @returns {'overlay'|'history'|'down'|'none'}
 */
export function mobileBackStep(s) {
  if (!s.mobile) return 'none'
  if (s.overlays > 0) return 'overlay'
  if (s.level === 1) return 'none'
  if (s.hasBelow) return 'history'
  if (s.level === 2 && s.up()) return 'none'
  return 'down'
}

/**
 * A route navigation finished (router.afterEach):
 *   'push' - it failed as a duplicate on a phone: a tap on the link to the
 *            page already behind level 1, so show level 2
 *   'tag'  - a fresh entry: a push from the level we were on
 *   'none' - another failure, or an entry tagged already (a replace writing
 *            ?topic=, or a popstate the popstate listener has applied;
 *            re-applying would race a topic that opened before its entry
 *            was pushed, and close it)
 * @param {'duplicated'|'other'|null} failure
 * @param {boolean} mobile
 * @param {1|2|3|null} tagged what the new entry says
 * @returns {'push'|'tag'|'none'}
 */
export function mobileAfterNavStep(failure, mobile, tagged) {
  if (failure) return failure === 'duplicated' && mobile ? 'push' : 'none'
  return tagged === null ? 'tag' : 'none'
}

/**
 * Where a back swipe starts, or null when this touch cannot be one: the
 * stack must be `active` (a phone above level 1) and one finger down.
 * @param {boolean} active
 * @param {ArrayLike<{ clientX: number, clientY: number }>|null|undefined} touches
 * @returns {{ x: number, y: number }|null}
 */
export function mobileSwipeStart(active, touches) {
  const p = touches && touches.length === 1 ? touches[0] : null
  return active && p ? { x: p.clientX, y: p.clientY } : null
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

/*
 * SPL-994: an overlay (a dialog, a bottom sheet) is the TOP level while it is
 * open. Opening one pushes a history entry that copies the entry under it and
 * adds MOBILE_OVERLAY_KEY = the overlay's id; Back (browser, gesture, chevron,
 * swipe) comes down onto the entry under it, and the shell closes the overlay
 * there without letting the router or the level see that popstate. The value
 * is null (not absent) once the overlay is gone: vue-router merges its own
 * cached copy of the state under history.state, so a deleted key comes back.
 */
export const MOBILE_OVERLAY_KEY = 'splOverlay'

/** vue-router's history position (state.position) of an entry, or null. */
export function mobileStatePosition(state) {
  return state && typeof state === 'object' && typeof state.position === 'number' ? state.position : null
}

/** The overlay id a history entry was pushed for, or null. */
export function mobileOverlayOf(state) {
  const v = state && typeof state === 'object' ? state[MOBILE_OVERLAY_KEY] : null
  return typeof v === 'number' && v > 0 ? v : null
}

/** history.state with the overlay tag set to `id` (null = no overlay). */
export function mobileOverlayState(state, id) {
  const base = state && typeof state === 'object' ? { ...state } : {}
  base[MOBILE_OVERLAY_KEY] = id || null
  return base
}

/**
 * A popstate arrived while overlays may be open. What does the shell do?
 *   { kind: 'none' }            - not about overlays: the router and the level handle it
 *   { kind: 'close', keep: n }  - Back landed on the entry of the n-th overlay (or under
 *                                 all of them, n = 0): close the ones above it and
 *                                 swallow the event (the page and the level stay put)
 *   { kind: 'leave' }           - Back went past every overlay entry (history.go(-k)):
 *                                 close them all, let the router navigate
 *   { kind: 'dead', back }      - the entry is of an overlay that is gone (Forward onto
 *                                 it, or one left behind): step past it. `back` = we
 *                                 came DOWN onto it, so the router must follow first.
 * @param {number[]} open the overlay ids with an entry, bottom -> top
 * @param {unknown} state the popstate's state
 * @param {number|null} lastPos history position (vue-router's state.position) we were on
 * @returns {{ kind: 'none' } | { kind: 'close', keep: number } | { kind: 'leave' } | { kind: 'dead', back: boolean }}
 */
export function mobileOverlayPop(open, state, lastPos) {
  const id = mobileOverlayOf(state)
  const pos = mobileStatePosition(state)
  const down = pos !== null && lastPos !== null && pos < lastPos
  if (id !== null && !open.includes(id)) return { kind: 'dead', back: down }
  if (open.length === 0) return { kind: 'none' }
  if (id !== null) {
    const keep = open.indexOf(id) + 1
    return keep === open.length ? { kind: 'none' } : { kind: 'close', keep }
  }
  return down ? { kind: 'leave' } : { kind: 'close', keep: 0 }
}

/**
 * c78fb3ec: the router is about to read the popped entry's URL. One tagged
 * below 3 that still names a topic (an older build wrote them) would open it
 * again - level 3, a new push, the same entry on the next Back, stuck until
 * the app restarts - so its topic is dropped first. Not when the shell
 * swallows the event: an overlay close, or a dead entry we came UP onto.
 * @param {{ kind: string, back?: boolean }} step mobileOverlayPop's answer
 */
export function mobilePopDropsTopic(step) {
  return step.kind !== 'close' && !(step.kind === 'dead' && !step.back)
}

/**
 * An overlay closed by its own X, backdrop or Escape (or unmounted):
 *   'back' - its entry is the current one: step back over it
 *   'drop' - its entry is gone already: just forget it
 *   'wait' - one above it is still open: its entry goes when that one goes
 *   'none' - it has no entry
 * @param {number[]} open the overlay ids with an entry, bottom -> top
 * @param {number} id the overlay that closed
 * @param {number|null} current mobileOverlayOf(history.state)
 * @returns {'back'|'drop'|'wait'|'none'}
 */
export function mobileOverlayCloseStep(open, id, current) {
  const i = open.indexOf(id)
  if (i < 0) return 'none'
  if (i < open.length - 1) return 'wait'
  return current === id ? 'back' : 'drop'
}

/*
 * 087 T003 (FR-001): Back never shows the sign-in page to a signed-in member.
 * A typed /login or an identity-provider round trip leaves a /login entry in
 * history; Back onto it painted "Signed in as ... Continue to topics". A
 * history step (popstate, a bfcache restore, a back_forward load) that lands
 * there with a signed-in session is stale: the shell replaces the entry with
 * the front door and steps back once more. A deliberate visit (typed, a link,
 * a reload) is not a history step, so it still shows the page.
 */
const MOBILE_LOGIN_PATH = /^(\/[a-z]{2}(-[A-Za-z]{2,4})?)?\/login\/?$/

/**
 * True when a history step onto `path` must not paint the sign-in page:
 * the path is /login (any locale prefix) and the session reads 'in'.
 * 'loading', 'unknown' and 'out' are not signed in: the page stays.
 * @param {string} path location.pathname (a query or hash is ignored)
 * @param {string} sessionState the session store's state
 */
export function isStaleLoginStep(path, sessionState) {
  if (sessionState !== 'in') return false
  return MOBILE_LOGIN_PATH.test(String(path || '').split(/[?#]/, 1)[0])
}

/** The front door under the login path's locale prefix: `/fi/login` -> `/fi`, `/login` -> `/`. */
export function mobileLoginFrontDoor(path) {
  const m = MOBILE_LOGIN_PATH.exec(String(path || '').split(/[?#]/, 1)[0])
  return (m && m[1]) || '/'
}

/**
 * A fresh document load of /login: does it wait for the session probe and
 * then leave as a stale step? Only a back_forward load (a history step), on a
 * phone, of a login path. The session is checked once the probe settles.
 * @param {string|undefined} navType PerformanceNavigationTiming.type
 * @param {boolean} phone the viewport matches MOBILE_STACK_QUERY
 * @param {string} path location.pathname
 */
export function mobileStaleLoginLoad(navType, phone, path) {
  return navType === 'back_forward' && phone && isStaleLoginStep(path, 'in')
}
