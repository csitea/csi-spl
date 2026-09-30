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
import { useViewerStore } from '~/stores/viewer'
import { topicErrorKey } from '~/utils/topic-archive.mjs'

/** Owner (topic f20c6052): the snackbar shows for this long. ONE constant. */
export const ARCHIVE_UNDO_MS = 700

type ArchiveToast = { id: number, msgId: string, busy: boolean }

const toast = shallowRef<ArchiveToast | null>(null)
let seq = 0

export function useArchiveUndo() {
  const api = useSpoolApi()
  const i18n = useNuxtApp().$i18n

  function dismiss() {
    toast.value = null
  }

  /** Offer Undo for the card just archived. Called after archiveTopic succeeds. */
  function offerUndo(msgId: string) {
    const id = String(msgId || '')
    if (!id) return
    toast.value = { id: ++seq, msgId: id, busy: false }
  }

  /* The archive dropped the card from every feed and list of this tab
     (useMessageEdit.dropEverywhere: the channel store, both live feeds, the
     topic-list rows); the unarchive re-reads them so the card comes back where
     it was. The other tabs get the hub's topic_archived(archived:false) frame. */
  async function restore() {
    await useChannelStore().catchUp().catch(() => {})
    await useViewerStore().catchUp().catch(() => {})
    for (const key of ['main', 'pane'] as const) {
      const feed = useLiveFeed(key)
      if (feed.taskId) await feed.open(String(feed.taskId)).catch(() => {})
    }
  }

  async function undo() {
    const t = toast.value
    if (!t || t.busy) return
    toast.value = { ...t, busy: true }
    try {
      await api.archiveTopic(t.msgId, false)
      await restore()
      toast.value = null
    } catch (e) {
      toast.value = null
      noteError({ source: 'archive-undo', name: 'ArchiveUndo', message: i18n.t(topicErrorKey(e, 'archive')), error: e })
    }
  }

  return { toast, offerUndo, undo, dismiss }
}
