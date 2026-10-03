import { nextTick } from 'vue'
import { useTopicStore } from '~/stores/topic'
import { useSidePane } from '~/composables/useSidePane'
import { withSessionRetry } from './live-follow.mjs'
import { scrollRowToTop } from './pane-scroll.mjs'
import { cardScrollDelta, issueKeyForTask, mayBeIssueTopic, parentSection, parentTopicOf } from './parent-section.mjs'

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

/** Scroll the parent card to the reader's edge, reading older pages for it,
    and keep the thread open on it - or, with no target, select the card
    `msgId` itself and open nothing. */
async function revealCard(topic, target, { router, hash, newestLast, msgId = '' }, { tries = 150, every = 100 } = {}) {
  const sel = target
    ? `.spool-main article.msg[data-task-id="${CSS.escape(target.taskId)}"]`
    : `.spool-main article.msg[data-msg-id="${CSS.escape(msgId)}"]`
  let pages = 0
  for (let i = 0; i < tries; i++) {
    const card = document.querySelector(sel)
    if (card) {
      if (target && (!topic.open || !topic.target || topic.target.taskId !== target.taskId)) {
        topic.openTarget(target, topic.rootMsg)
        await sleep(0)
        if (hash) await router.replace({ hash })
      }
      const scroller = card.closest('.feed-body')
      if (scroller) {
        const pad = parseFloat(getComputedStyle(scroller).paddingBottom) || 0
        scroller.scrollTop += cardScrollDelta(card.getBoundingClientRect(), scroller.getBoundingClientRect(), newestLast, pad)
      }
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
