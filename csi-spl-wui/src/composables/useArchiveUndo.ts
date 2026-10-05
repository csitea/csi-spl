// SPL-1264 (CLE-77809): "Archived · Undo". After a card is archived (a topic
// row, a message/topic card menu, the delete dialog's Archive link - every path
// that calls api.archiveTopic(id, true)), the caller shows this snackbar; Undo
// hits the SAME endpoint with archived=false (the Archive page's Unarchive) and
// brings the card back to this tab's feeds and topic lists.
//
// It mirrors useMove's one-toast-per-tab shape (714c7028): the toast state is a
// module singleton, so the archiving component and the snackbar in the shell
// share it. The snackbar itself (UndoSnackbar) owns the auto-dismiss timer.
import { noteError } from '~/composables/errorJournal.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useTopicStore } from '~/stores/topic'
import { useViewerStore } from '~/stores/viewer'
import { reselectRow } from '~/utils/reselect-row.mjs'
import { topicErrorKey } from '~/utils/topic-archive.mjs'

/** Owner (topic f20c6052): the snackbar shows for this long. ONE constant. */
export const ARCHIVE_UNDO_MS = 700

/* The archive dropped the card from every feed and list of this tab
   (useMessageEdit.dropEverywhere: the channel store, both live feeds, the
   topic-list rows); the unarchive re-reads them so the card comes back where
   it was. The other tabs get the hub's topic_archived(archived:false) frame.
   CLE-77840: the Deleted · Undo snackbar (useDeleteUndo) re-reads the same way.
   Every step is best effort and runs in order: one that fails does not stop
   the next, and the caller never sees the error. */
export async function rereadFeeds() {
  // A failed re-read only leaves the card hidden until the next live frame or reconnect catch-up.
  await useChannelStore().catchUp().catch(() => {})
  // Same: the viewer list catches up again on the next frame or reconnect.
  await useViewerStore().catchUp().catch(() => {})
  for (const key of ['main', 'pane'] as const) {
    const feed = useLiveFeed(key)
    // Same: the open feed re-reads on the next live frame or reconnect catch-up.
    if (feed.taskId) await feed.open(String(feed.taskId)).catch(() => {})
  }
}

/* Owner (t1 5108d85d): "when a topic is archived - if it has the right pane
   opened on desktop it should close". Every archive path (a topic row, a card
   menu, the delete dialog's Archive link) goes through the client's
   archiveTopic, which fires `spool:topic-archived`; the shell hands that
   event's detail here, so the pane closes in ONE place. The topic is named by
   its card (msgId: a message-rooted topic's task IS that id) and its task.
   Other topics' panes stay; Undo (archived: false) does not reopen it. */
export function closeArchivedPane(detail: { msgId?: string, taskId?: string, archived?: boolean } | null | undefined, lobbyTaskId = '') {
  if (!detail || detail.archived !== true) return
  const lobby = String(lobbyTaskId || '')
  const ids = new Set([detail.msgId, detail.taskId].map((x) => String(x || '')).filter((x) => x && x !== lobby))
  if (!ids.size) return
  const pane = useLiveFeed('pane')
  if (pane.taskId && ids.has(String(pane.taskId))) pane.close()
  const topic = useTopicStore()
  if (topic.open && (ids.has(String(topic.parentTaskId || '')) || ids.has(String(topic.target?.rootMsgId || '')))) topic.close()
}

type ArchiveToast = { id: number, msgId: string, pane: string, busy: boolean }

const toast = shallowRef<ArchiveToast | null>(null)
let seq = 0

export function useArchiveUndo() {
  const api = useSpoolApi()
  const i18n = useNuxtApp().$i18n

  function dismiss() {
    toast.value = null
  }

  /** Offer Undo for the card just archived. Called after archiveTopic succeeds.
      `pane` ('topic' / 'main', utils/reselect-row) is where it was, so Undo
      selects it there again; 'rail' (a left-rail topic row) selects no card. */
  function offerUndo(msgId: string, pane = '') {
    const id = String(msgId || '')
    if (!id) return
    toast.value = { id: ++seq, msgId: id, pane, busy: false }
  }

  async function undo() {
    const t = toast.value
    if (!t || t.busy) return
    toast.value = { ...t, busy: true }
    try {
      await api.archiveTopic(t.msgId, false)
      await rereadFeeds()
      toast.value = null
      /* CLE-77871: the card that came back is selected again, as before */
      if (t.pane !== 'rail') void reselectRow(t.msgId, { pane: t.pane })
    } catch (e) {
      toast.value = null
      noteError({ source: 'archive-undo', name: 'ArchiveUndo', message: i18n.t(topicErrorKey(e, 'archive')), error: e })
    }
  }

  return { toast, offerUndo, undo, dismiss }
}
