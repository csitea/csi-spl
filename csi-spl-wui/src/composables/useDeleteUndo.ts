// CLE-77840 (owner, t1 topic bc1fd547): "Deleted · Undo". Delete on a selected
// REPLY (is_parent 0) removes it at once, with no confirm, and offers Undo the
// way archiving does (useArchiveUndo, SPL-1264).
//
// The hub's DELETE /v1/messages/{id} is a hard delete (the row and its
// deliveries go), so Undo cannot be a second call. Instead the delete is a
// DELAYED COMMIT: the row leaves every feed of this tab at once, the DELETE is
// sent only when the snackbar closes (its 0.7 s - 6 s on a touch UI, CLE-77871 -, Esc, the X, or the next
// delete), and Undo before that sends nothing and re-reads the feeds. Other
// tabs learn of it from the hub's message_deleted frame once it is sent. A tab
// closed inside the window still sends it on pagehide (best effort): if that
// request is lost the message stays, which is the safe way to fail.
//
// Bringing it back: the stores re-read from the hub (rereadFeeds, as the
// archive Undo does), and a host that keeps its OWN copy of the rows (the
// channel topic pane, TopicPane.vue) re-inserts the row it is handed through
// onRestore. One toast per tab, a module singleton, so the deleting card, the
// hosts and the snackbar in the shell share it.
import { noteError } from '~/composables/errorJournal.mjs'
import { ARCHIVE_UNDO_MS, rereadFeeds } from '~/composables/useArchiveUndo'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { editFailureKey } from '~/utils/msg-edit.mjs'
import type { SpoolMessage } from '~/types/spool'

/** The owner asked for the same snackbar as archiving: the same window. */
export const DELETE_UNDO_MS = ARCHIVE_UNDO_MS

type DeleteToast = { id: number, msgId: string, busy: boolean }
type Restore = (row: SpoolMessage) => void

const toast = shallowRef<DeleteToast | null>(null)
let seq = 0
/** The row whose DELETE is not sent yet (null = none). */
let pending: SpoolMessage | null = null
/** Its msg_id, reactive: every feed (LiveFeed) hides it while it is pending.
    The hub still holds the row until the DELETE goes, so a re-read inside the
    window (a poll, a reconnect catch-up) would otherwise bring it back. */
export const pendingDeleteId = ref('')
function setPending(row: SpoolMessage | null) {
  pending = row
  pendingDeleteId.value = row ? String(row.msg_id || '') : ''
}
let unloadHooked = false
const restorers = new Set<Restore>()

/** A host that holds its own rows re-inserts `row` on Undo. Returns the off switch. */
export function onDeleteRestore(fn: Restore): () => void {
  restorers.add(fn)
  return () => { restorers.delete(fn) }
}

async function bringBack(row: SpoolMessage) {
  for (const fn of restorers) fn(row)
  await rereadFeeds()
}

export function useDeleteUndo() {
  const api = useSpoolApi()
  const i18n = useNuxtApp().$i18n
  const { dropEverywhere } = useMessageEdit()

  async function send(row: SpoolMessage) {
    try {
      await api.deleteMessage(String(row.msg_id || ''))
    } catch (e) {
      /* refused (not_author, offline): the row was only hidden here, so it
         comes back, and the reason is journaled */
      await bringBack(row)
      noteError({ source: 'delete-undo', name: 'DeleteUndo', message: i18n.t(editFailureKey(e)), error: e })
    }
  }

  /** Send the pending DELETE now (the snackbar closed, or a new delete came). */
  function commit() {
    const row = pending
    setPending(null)
    if (row) void send(row)
  }

  /** Delete `row` with Undo: hide it now, send the DELETE when the snackbar closes. */
  function offer(row: SpoolMessage) {
    const id = String(row?.msg_id || '')
    if (!id) return
    if (!unloadHooked && typeof window !== 'undefined') {
      unloadHooked = true
      window.addEventListener('pagehide', () => commit())
    }
    commit() /* the previous one is final once the next delete starts */
    setPending(row)
    dropEverywhere(id)
    toast.value = { id: ++seq, msgId: id, busy: false }
  }

  function dismiss() {
    toast.value = null
    commit()
  }

  async function undo() {
    const t = toast.value
    if (!t || t.busy) return
    const row = pending && String(pending.msg_id || '') === t.msgId ? pending : null
    if (!row) return /* already sent (the page was hiding): nothing to undo */
    setPending(null)
    toast.value = { ...t, busy: true }
    await bringBack(row)
    toast.value = null
  }

  return { toast, offer, undo, dismiss }
}
