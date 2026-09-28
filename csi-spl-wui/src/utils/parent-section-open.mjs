import { useTopicStore } from '~/stores/topic'
import { withSessionRetry } from './live-follow.mjs'
import { issueKeyForTask, mayBeIssueTopic, parentSection, parentTopicOf } from './parent-section.mjs'

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
 *
 * @param {Record<string, any>} msg
 * @param {{ self: string, api: any, router: any, localePath: (p: string) => string }} deps
 * @returns {Promise<boolean>} false when the message names no parent
 */
export async function openParentSection(msg, deps) {
  const { self, api, router, localePath } = deps
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
  const to = parentSection(msg, { self, target: open, issueKey })
  if (!to) return false
  if (to.kind === 'issue') {
    await router.push({ path: localePath(to.path), query: to.query })
    return true
  }
  const taskId = String(to.query.topic || '')
  const target = open && open.taskId === taskId
    ? open
    : { taskId, mode: to.query.in ? 'message' : 'task', rootMsgId: to.query.in ? taskId : '', parentTaskId: String(to.query.in || '') }
  await router.push({ path: localePath(to.path), query: to.query, hash: to.hash })
  if (taskId && !topic.open) topic.openTarget(target, topic.rootMsg)
  if (taskId) await revealCard(topic, target, { router, hash: to.hash })
  return true
}

/** The list's pages it may read back for the parent card. */
export const REVEAL_PAGES = 10

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** Scroll the parent card into view, reading older pages for it, and keep
    the thread open on it. */
async function revealCard(topic, target, { router, hash }, { tries = 150, every = 100 } = {}) {
  const sel = `.spool-main article.msg[data-task-id="${CSS.escape(target.taskId)}"]`
  let pages = 0
  for (let i = 0; i < tries; i++) {
    const card = document.querySelector(sel)
    if (card) {
      if (!topic.open || !topic.target || topic.target.taskId !== target.taskId) {
        topic.openTarget(target, topic.rootMsg)
        await sleep(0)
        if (hash) await router.replace({ hash })
      }
      const scroller = card.closest('.feed-body')
      if (scroller) scroller.scrollTop += card.getBoundingClientRect().top - scroller.getBoundingClientRect().top
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
