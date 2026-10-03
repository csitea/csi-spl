// SPL-986 (specs/041 §3.5): Archive and Delete on a topic ROW - the left-rail
// Topics section, the Flow list and the Topics home - with the card menu's
// own entries, confirm dialog, endpoints and permission rule (SPL-983).
//
// A row is a task; the hub acts on its card. The card is found when the row's
// menu opens (utils/topic-archive.mjs rowCardCandidates / isRowTopic) and the
// hub's own answer (can_archive / can_delete) decides what is offered, so a
// row never offers what the hub would refuse. Nothing is read for a row whose
// menu is never opened.
import { noteError } from '@/composables/errorJournal.mjs'
import { useArchiveUndo } from '~/composables/useArchiveUndo'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { useViewerStore } from '~/stores/viewer'
import { useLiveFeed } from '~/stores/live'
import { useTopicStore } from '~/stores/topic'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { isRowTopic, rowCardCandidates, rowTopicState, topicErrorKey, type RowTopicState } from '~/utils/topic-archive.mjs'

type RowState = RowTopicState | { state: 'loading', msgId: '', canArchive: false, canDelete: false, replies: 0 }

export function useTopicRowActions() {
  const api = useSpoolApi()
  const live = useLive()
  const viewer = useViewerStore()
  const { dropEverywhere } = useMessageEdit()
  const archiveUndo = useArchiveUndo()
  const i18n = useNuxtApp().$i18n
  const rows = ref<Record<string, RowState>>({})

  function stateOf(taskId: string): RowState | null {
    return rows.value[String(taskId || '')] || null
  }

  /* HUM-10 (phone swipe on a Topics row): a second caller awaits the read
     already in flight instead of seeing the 'loading' placeholder */
  const inflight = new Map<string, Promise<void>>()

  /** Find the row's card and ask the hub what the viewer may do. Once per row. */
  function resolve(taskId: string): Promise<void> {
    const task = String(taskId || '')
    if (!task) return Promise.resolve()
    const pending = inflight.get(task)
    if (pending) return pending
    if (rows.value[task]) return Promise.resolve()
    const run = read(task).finally(() => inflight.delete(task))
    inflight.set(task, run)
    return run
  }

  async function read(task: string) {
    rows.value = { ...rows.value, [task]: { state: 'loading', msgId: '', canArchive: false, canDelete: false, replies: 0 } }
    const lobby = String(live.lobbyTaskId.value || '')
    let found: RowTopicState = rowTopicState(null, '')
    try {
      const first = task === lobby
        ? null
        : (await withSessionRetry(api, () => api.getTopic(task, { limit: 1 }))).messages[0] || null
      for (const id of rowCardCandidates(task, first, lobby)) {
        try {
          const size = await withSessionRetry(api, () => api.topicSize(id))
          if (isRowTopic(size, task, id, lobby)) {
            found = rowTopicState(size, id)
            break
          }
        } catch {
          /* 404 / 409 not_a_card: not this one, try the next */
        }
      }
    } catch {
      /* the row stays without the entries; the menu's other items still work */
    }
    rows.value = { ...rows.value, [task]: found }
  }

  /** A removed topic leaves every list and feed on this screen. */
  function drop(taskIds: string[], msgIds: string[]) {
    for (const id of msgIds) dropEverywhere(id)
    viewer.dropTopics(taskIds)
    const gone = new Set(taskIds.map(String))
    const pane = useLiveFeed('pane')
    if (pane.taskId && gone.has(String(pane.taskId))) pane.close()
    const topic = useTopicStore()
    if (topic.open && gone.has(String(topic.parentTaskId || ''))) topic.close()
    const next = { ...rows.value }
    for (const id of gone) delete next[id]
    rows.value = next
  }

  /** true once the topic is archived (the row swipe snaps back otherwise) */
  async function archive(taskId: string): Promise<boolean> {
    const task = String(taskId || '')
    const row = stateOf(task)
    if (!row || row.state !== 'ready' || !row.canArchive) return false
    try {
      await api.archiveTopic(row.msgId, true)
      drop([task, row.msgId], [row.msgId])
      /* SPL-1264: offer Undo (the same endpoint, archived=false) for 0.7 s */
      archiveUndo.offerUndo(row.msgId, 'rail')
      return true
    } catch (e) {
      noteError({ source: 'topic-archive', name: 'TopicArchive', message: i18n.t(topicErrorKey(e, 'archive')), error: e })
      return false
    }
  }

  /** The confirm dialog (TopicDeleteDialog, the card's own). */
  const deleteOpen = ref(false)
  const deleteTask = ref('')
  const deleteMsgId = computed(() => {
    const row = stateOf(deleteTask.value)
    return row && row.state === 'ready' ? row.msgId : ''
  })
  function askDelete(taskId: string) {
    const row = stateOf(taskId)
    if (!row || row.state !== 'ready' || !row.canDelete) return
    deleteTask.value = String(taskId)
    deleteOpen.value = true
  }
  function onDeleted(out: { msg_ids: string[], task_ids: string[] }) {
    const task = deleteTask.value
    drop([task, ...(out.task_ids || [])].filter(Boolean), out.msg_ids || [])
  }

  return { rows, stateOf, resolve, archive, deleteOpen, deleteTask, deleteMsgId, askDelete, onDeleted }
}
