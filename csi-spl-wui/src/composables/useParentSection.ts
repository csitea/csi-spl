import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'
import { useTopicStore, type TopicTarget } from '~/stores/topic'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { issueKeyForTask, mayBeIssueTopic, parentSection, parentTopicOf } from '~/utils/parent-section.mjs'
import type { SpoolMessage } from '~/types/spool'

/**
 * CLE-34996 (SPL-15): "Open parent section" from a thread message's menu.
 *
 * The address is utils/parent-section.mjs. What this adds is the part that
 * needs the app: who the viewer is (the DM end that is not the peer), the
 * hub's answer to "is this #tasks topic an issue", and the hand-over of the
 * open thread. A thread opened from /search sits in the live pane; the
 * channel and DM pages show theirs in the channel topic pane, and a target
 * that did not change opens nothing (useTopicRoute), so once the page is
 * there the same target is opened again through openTarget, which moves the
 * thread into that page's pane. `topic.reveal` asks the middle list to
 * bring the parent card into view (LiveFeed) and keeps the page from
 * closing the thread while it looks further back for it.
 */
export function useParentSection() {
  const api = useSpoolApi()
  const live = useLive()
  const access = useAccessStore()
  const roster = useRosterStore()
  const topic = useTopicStore()
  const router = useRouter()
  const localePath = useLocalePath()

  const self = computed(() => String(access.me?.humanId || live.identity.value || roster.me?.id || ''))

  /** Does this message name a place to go back to? */
  function hasParent(msg: SpoolMessage | null | undefined): boolean {
    return Boolean(msg && parentSection(msg, { self: self.value }))
  }

  async function issueKeyOf(msg: SpoolMessage): Promise<string> {
    if (!mayBeIssueTopic(msg)) return ''
    const task = topic.target?.taskId || parentTopicOf(msg)
    try {
      const list = await withSessionRetry(api, () => api.listIssues())
      return issueKeyForTask(list, task)
    } catch {
      /* no answer: #tasks is still the place the message was posted in */
      return ''
    }
  }

  async function openParent(msg: SpoolMessage): Promise<boolean> {
    const open = topic.target ? { ...topic.target } as TopicTarget : null
    const issueKey = await issueKeyOf(msg)
    const to = parentSection(msg, { self: self.value, target: open, issueKey })
    if (!to) return false
    if (to.kind === 'issue') {
      await router.push({ path: localePath(to.path), query: to.query })
      return true
    }
    const target: TopicTarget = open && open.taskId === to.query.topic
      ? open
      : { taskId: String(to.query.topic || ''), mode: to.query.in ? 'message' : 'task', rootMsgId: to.query.in ? String(to.query.topic || '') : '', parentTaskId: String(to.query.in || '') }
    if (target.taskId) topic.revealParent(target.taskId)
    await router.push({ path: localePath(to.path), query: to.query, hash: to.hash })
    if (target.taskId && !topic.open) topic.openTarget(target, topic.rootMsg)
    return true
  }

  return { self, hasParent, openParent }
}
