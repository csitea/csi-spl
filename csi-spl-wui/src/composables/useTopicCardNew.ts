import { computed, type Ref } from 'vue'
import { useNotificationStore } from '~/stores/notification'
import { loadCursors, openerUnseen } from '~/utils/read-cursor.mjs'
import { flowTopicUnread } from '~/composables/useFlowBadge'
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
 */
export function useTopicCardNew(boundary: () => Cursor | null | undefined, viewerId: Ref<string>) {
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
  return { openerNew, hubUnread }
}
