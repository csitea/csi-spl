import { computed, type Ref } from 'vue'
import { useNotificationStore } from '~/stores/notification'
import { loadCursors, openerUnseen } from '~/utils/read-cursor.mjs'
import { topicCounts } from '~/utils/topic-counts.mjs'
import { useFlowKeys } from '~/composables/useFlowBadge'
import type { SpoolMessage } from '~/types/spool'

type Cursor = { ts?: string, id?: string }

/**
 * A feed's topic cards, the parts of "<new>/<total>" beyond the local reply
 * count (LiveFeed asks only for its counted rows).
 *
 *  - openerNew(m): SPL-2422 (owner, t1 89010926): a topic's first message
 *    counts as 1 new for a reader who has not seen it (openerUnseen: after
 *    their t: mark, or with no mark after this feed's boundary). The marks
 *    are re-read as one moves (topicRead), so opening the topic clears it.
 *  - hubUnread(m): SPL-2506 (owner, t1 d8fa6f9c): the hub's t: key for the
 *    topic, the part of its channel badge it holds (flowTopicUnread).
 *  - unseen(m): SPL-2506 (owner, t1 43a1030f): the card's "<new>" number
 *    (topicCounts), what the unread-first order reads (useUnreadOrder).
 *  - opened(m): opening the card zeroes its topic's hub t: key at once,
 *    until the hub's next counts (here, not in the eager store).
 */
/**
 * SPL-2506 (owner, t1 d8fa6f9c): the hub's unread for one topic, its
 * t:<task_id> key, the part of the channel badge (ch:) that topic holds. A
 * topic card shows at least this (topicCounts), so a counted line is always
 * marked on its card. 0 when unknown. Here, not in useFlowBadge, so it stays
 * off the initial script.
 */
export function flowTopicUnread(taskId: string) {
  return (taskId && Number(useFlowKeys().value?.[`t:${taskId}`])) || 0
}

type Counts = { countFor?: (taskId: string) => number, unreadFor?: (taskId: string) => number }

export function useTopicCardNew(boundary: () => Cursor | null | undefined, viewerId: Ref<string>, feed: Counts = {}) {
  const notes = useNotificationStore()
  const topicMarks = computed<Record<string, Cursor>>(() => {
    void notes.topicRead
    return import.meta.client ? loadCursors() : {}
  })
  function openerNew(m: SpoolMessage) {
    if (!m.task_id) return false
    return openerUnseen(m, topicMarks.value[`t:${m.task_id}`], boundary(), viewerId.value)
  }
  function hubUnread(m: SpoolMessage) {
    return flowTopicUnread(String(m.task_id || ''))
  }
  function unseen(m: SpoolMessage) {
    const { countFor, unreadFor } = feed
    const tid = String(m.task_id || '')
    if (!countFor || !unreadFor) return 0
    return topicCounts(countFor(tid), unreadFor(tid), openerNew(m), hubUnread(m)).unseen
  }
  function opened(m: SpoolMessage) {
    const keys = useFlowKeys()
    const k = `t:${m.task_id || ''}`
    if (keys.value?.[k]) keys.value = { ...keys.value, [k]: 0 }
  }
  return { openerNew, hubUnread, unseen, opened }
}
