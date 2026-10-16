import { nextTick } from 'vue'
import { useTopicStore } from '~/stores/topic'
import { useSidePane } from '~/composables/useSidePane'
import { withSessionRetry } from './live-follow.mjs'
import { scrollRowToTop } from './pane-scroll.mjs'
import { cardScrollDelta, hashOnlyLocation, issueKeyForTask, mayBeIssueTopic, parentSection, parentTopicOf } from './parent-section.mjs'

/**
 * (SPL-15): what "Open parent section" does, loaded only when the
 * item is chosen (MessageCard imports this file dynamically). The initial
 * JS is at its 210 KB gzip ceiling (specs/027 perf-budgets.json), so none of
 * this sits in the chunk every page loads.
 *
 * 1. The issue channel (or the retired #tasks): ask the hub which issue's
 *    discussion the topic is; if one, go to /issues?issue=<key>.
 * 2. Otherwise go to the channel or DM with ?topic= and #<msg>. A thread
 *    opened from /search sits in the live pane; a target that did not change
 *    opens nothing on the new page (useTopicRoute), so the same target is
 *    opened again through openTarget, which moves the thread into that
 *    page's own topic pane.
 * 3. Bring the parent card into view in the middle, pressing the list's
 *    Load more (at most REVEAL_PAGES times) while it is not there yet. A
 *    page whose first rows lack the card releases the topic
 *    (useTopicFeedClose); once the card is loaded the same target and hash
 *    are opened again.
 * 4. HUM-10 (topic c15b557e): the card lands at the reader's edge - the top
 *    of the list when they read newest first, the bottom when newest last
 *    (`newestLast`, Settings -> Behaviour "Message order"). A topic's own
 *    opening card stops at the topic level: the channel or DM selected, the
 *    card selected (focused) at that edge, the topic NOT opened.
 * 5. HUM-10 (topic c15b557e, 13:19Z): the card menu's jump (`showPlace`)
 *    lands fully in its place - the first left panel switches from the list
 *    it holds (the Flow) to Channels (or Direct messages), so the channel row
 *    is the selected one, and a reply is selected (focused) in its thread
 *    even when the address did not change. The Flow's own open
 *    (open-message.mjs) keeps its list.
 *
 * 6. HUM-10 (t1 89b0200d): a message of an archived topic (`msg.archived`,
 *    open-message.mjs) opens the same way, but its card is in no feed: the
 *    topic is opened on the right without waiting for the card, and it stays
 *    open on this place (target.archived, keepsArchivedTopic).
 *
 * @param {Record<string, any>} msg
 * @param {{ self: string, api: any, router: any, localePath: (p: string) => string, newestLast?: boolean, topicLevel?: boolean, showPlace?: boolean }} deps
 * @returns {Promise<boolean>} false when the message names no parent
 */
export async function openParentSection(msg, deps) {
  const { self, api, router, localePath } = deps
  const newestLast = Boolean(deps.newestLast)
  const topic = useTopicStore()
  const open = topic.target ? { ...topic.target } : null
  let issueKey = ''
  if (mayBeIssueTopic(msg)) {
    try {
      const list = await withSessionRetry(api, () => api.listIssues())
      issueKey = issueKeyForTask(list, (open && open.taskId) || parentTopicOf(msg))
    } catch {
      /* no answer: the Issues tab (or the retired #tasks) is still the place */
    }
  }
  const to = parentSection(msg, { self, target: open, issueKey, topicLevel: Boolean(deps.topicLevel) })
  if (!to) return false
  if (to.kind === 'issue') {
    await router.push({ path: localePath(to.path), query: to.query })
    return true
  }
  const showPlace = Boolean(deps.showPlace)
  if (showPlace) {
    /* the sidebar drops the list it holds (the Flow) for the place's own */
    useSidePane().reveal(to.kind === 'dm' ? 'dm' : 'channels')
    await nextTick()
  }
  const taskId = String(to.query.topic || '')
  if (!taskId) {
    /* a topic's opening card: no topic is opened, the card itself is selected */
    await router.push({ path: localePath(to.path), query: {} })
    if (topic.open) topic.close()
    await revealCard(topic, null, { router, hash: '', newestLast, msgId: String(msg.msg_id || '') })
    return true
  }
  const target = open && open.taskId === taskId
    ? open
    : { taskId, mode: to.query.in ? 'message' : 'task', rootMsgId: to.query.in ? taskId : '', parentTaskId: String(to.query.in || '') }
  await router.push({ path: localePath(to.path), query: to.query, hash: to.hash })
  if (msg.archived === true) {
    const here = String((router.currentRoute && router.currentRoute.value && router.currentRoute.value.path) || localePath(to.path))
    topic.openTarget({ ...target, archived: here }, topic.rootMsg)
    if (showPlace && to.hash) await selectReply(to.hash.slice(1))
    return true
  }
  if (!topic.open) topic.openTarget(target, topic.rootMsg)
  await revealCard(topic, target, { router, hash: to.hash, newestLast })
  if (showPlace && to.hash) await selectReply(to.hash.slice(1))
  return true
}

/** The thread line `msgId` selected (focused) and at the top of its thread,
    once the thread shows it. The thread does this itself for a new #hash;
    the same hash again (the card was opened from there) needs it here. */
async function selectReply(msgId, { tries = 50, every = 100 } = {}) {
  const sel = `aside.live-pane article.msg[data-msg-id="${CSS.escape(msgId)}"]`
  for (let i = 0; i < tries; i++) {
    const row = document.querySelector(sel)
    if (row) {
      if (document.activeElement === row) return
      const scroller = row.closest('.feed-body')
      if (scroller) scrollRowToTop(scroller, row)
      row.focus({ preventScroll: true })
      return
    }
    await sleep(every)
  }
}

/** The list's pages it may read back for the parent card. */
export const REVEAL_PAGES = 10

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** Frames the card must keep its place before the hold lets go, and the cap. */
const HOLD_STILL_FRAMES = 10
const HOLD_MAX_MS = 2000

/** SPL-1762: keep the card at the reader's edge while the feed settles. The
    tail under the list lands a frame late, and a card off screen is laid out
    at its content-visibility estimate until it is drawn: once the card is in
    view the rows beside it are drawn at their real height and move it, on a
    slow machine after the first re-measure. Re-apply every frame until the
    card has kept its place HOLD_STILL_FRAMES frames (at most HOLD_MAX_MS);
    the reader's own wheel, touch, key or pointer lets go at once. */
function holdCard(card, scroller, apply) {
  if (typeof requestAnimationFrame !== 'function') return
  const until = Date.now() + HOLD_MAX_MS
  const inputs = ['wheel', 'touchstart', 'keydown', 'pointerdown']
  let done = false
  const stop = () => {
    done = true
    for (const t of inputs) scroller.removeEventListener(t, stop)
  }
  for (const t of inputs) scroller.addEventListener(t, stop, { passive: true })
  let last = NaN
  let still = 0
  const tick = () => {
    if (done) return
    if (!card.isConnected || Date.now() > until) return stop()
    apply()
    const at = card.getBoundingClientRect().top - scroller.getBoundingClientRect().top
    still = Math.abs(at - last) < 1 ? still + 1 : 0
    last = at
    if (still >= HOLD_STILL_FRAMES) return stop()
    requestAnimationFrame(tick)
  }
  requestAnimationFrame(tick)
}

/** Put the card at the reader's edge of its scroller and hold it there while the feed settles. */
function landCard(card, scroller, newestLast) {
  const apply = () => {
    if (!card.isConnected) return
    const pad = parseFloat(getComputedStyle(scroller).paddingBottom) || 0
    scroller.scrollTop += cardScrollDelta(card.getBoundingClientRect(), scroller.getBoundingClientRect(), newestLast, pad)
  }
  apply()
  holdCard(card, scroller, apply)
}

/** Scroll the parent card to the reader's edge, reading older pages for it,
    and keep the thread open on it - or, with no target, select the card
    `msgId` itself and open nothing.
    It stops once the reader is on another page: a reveal still polling for
    the #alerts card re-opened that topic over the #lobby one a notification
    tap had just opened, and its ?topic= was then dropped as not in #lobby
    (links-open-channel-view 390px, open-in-place 1440 case 12). */
async function revealCard(topic, target, { router, hash, newestLast, msgId = '', alive = () => true }, { tries = 150, every = 100 } = {}) {
  const sel = target
    ? `.spool-main article.msg[data-task-id="${CSS.escape(target.taskId)}"]`
    : `.spool-main article.msg[data-msg-id="${CSS.escape(msgId)}"]`
  const here = routePath(router)
  const stale = () => !alive() || routePath(router) !== here
  let pages = 0
  for (let i = 0; i < tries; i++) {
    if (stale()) return
    const card = document.querySelector(sel)
    if (card) {
      if (target && (!topic.open || !topic.target || topic.target.taskId !== target.taskId)) {
        topic.openTarget(target, topic.rootMsg)
        await sleep(0)
        if (stale()) return
        if (hash) await router.replace(hashOnlyLocation(router.currentRoute && router.currentRoute.value, hash))
      }
      const scroller = card.closest('.feed-body')
      if (scroller) landCard(card, scroller, newestLast)
      if (!target) card.focus({ preventScroll: true, focusVisible: true })
      return
    }
    const feed = document.querySelector('.spool-main [role="feed"]')
    const busy = !feed || feed.getAttribute('aria-busy') === 'true'
    const more = document.querySelector('.spool-main [data-testid="load-more"]')
    if (!busy && more && !more.disabled && pages < REVEAL_PAGES) {
      pages += 1
      more.click()
    } else if (!busy && !more) {
      return
    }
    await sleep(every)
  }
}

/** Scroll the topic card named by ?topic= to the reader's edge.
    A plain link does not run the menu's openParentSection, so the channel
    and direct-message feeds call this when the address carries ?topic=. */
export function scrollTopicCard({ router, newestLast = false, taskId = '', hash = '', alive = () => true } = {}) {
  if (typeof document === 'undefined') return Promise.resolve()
  const id = String(taskId || '')
  if (!id) return Promise.resolve()
  const topic = useTopicStore()
  const target = { taskId: id, mode: 'task', rootMsgId: '', parentTaskId: '' }
  return revealCard(topic, target, { router, hash: String(hash || ''), newestLast: Boolean(newestLast), alive })
}

function routePath(router) {
  return String((router && router.currentRoute && router.currentRoute.value && router.currentRoute.value.path) || '')
}

/** The quiet time after the last size change before the card lands again. */
const RESIZE_SETTLE_MS = 100
const READER_INPUTS = ['wheel', 'touchstart', 'keydown', 'pointerdown']

/** SPL-2150: the room after the list was sized once, at landing, so a pane
    that grew later (a taller window, a phone turned, the list shown again on
    a phone) clamped the scroll and the ?topic= card slid down. Follow the
    pane's height: hand each settled height to setTail (it resolves once the
    tail is drawn) and land the card again, until the reader moves the pane
    themselves. Returns the function that stops following.
 */
export function followTopicPane({ scroller, taskId = '', newestLast = () => false, setTail = async () => {} } = {}) {
  const id = String(taskId || '')
  if (!scroller || !id || typeof ResizeObserver !== 'function') return () => {}
  let landed = true
  let timer
  const leave = () => { landed = false }
  const settle = async () => {
    const h = scroller.clientHeight
    if (h <= 0) return
    await setTail(h)
    if (!landed) return
    const card = scroller.querySelector(`article.msg[data-task-id="${CSS.escape(id)}"]`)
    if (card) landCard(card, scroller, Boolean(newestLast()))
  }
  const ro = new ResizeObserver(() => {
    clearTimeout(timer)
    timer = setTimeout(() => { void settle() }, RESIZE_SETTLE_MS)
  })
  for (const t of READER_INPUTS) scroller.addEventListener(t, leave, { passive: true })
  ro.observe(scroller)
  return () => {
    clearTimeout(timer)
    ro.disconnect()
    for (const t of READER_INPUTS) scroller.removeEventListener(t, leave)
  }
}
