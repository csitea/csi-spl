/*
 * Spec 155 2.10 (SPL-5255, owner HUM-10 t1 b7eb7c9a): what a note's menu
 * does, for the Notes list (pages/notes.vue) and the Archive part
 * (components/ArchiveNotes.vue), the open note included.
 *
 *   archive(id)   PATCH archived=true at once, no confirm; the Undo snackbar
 *                 PATCHes it back (owner msgs 79092e0b + ac509205)
 *   unarchive(id) PATCH archived=false (the Archive part's own action)
 *   remove(id)    D2: the note leaves the list at once, no confirm; the
 *                 DELETE (hard: the hub keeps no trash) goes when the 10 s
 *                 Undo snackbar ends or the page goes; Undo sends nothing
 *   discuss(id)   a new topic in the workspace's lobby whose first post is the
 *                 note's text (utils/note-menu.mjs noteDiscussionBody); the
 *                 note stays as it is and gains a `topic` link to it, and the
 *                 snackbar's Open goes there
 *
 * One snackbar at a time (`toast`): a new action settles the last one first
 * (a pending DELETE is sent). The snackbar sits at the bottom on a phone and
 * at the top on a desktop (UndoSnackbar `flip`).
 */
import { useNotesStore, type NoteSummary } from '~/stores/notes'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useAddToNote } from '~/composables/useAddToNote'
import { NOTE_DISCUSSION_CHANNEL, noteDiscussionBody } from '~/utils/note-menu.mjs'
import type { UiIconName } from '~/utils/uiIcons'

/* D2 (spec 155 section 3): the Undo window of Archive and Delete */
export const NOTE_UNDO_MS = 10_000

export type NoteToast =
  | { kind: 'archive', id: string, seq: number }
  | { kind: 'delete', id: string, row: NoteSummary, seq: number }
  | { kind: 'discuss', id: string, taskId: string, seq: number }
  | { kind: 'failed', id: string, seq: number }

type SendApi = { sendMessage(o: { channel?: string, text?: string, task_id?: string, is_parent?: 0 | 1 }): Promise<{ task_id?: string }> }

function newTaskId() {
  return globalThis.crypto?.randomUUID ? globalThis.crypto.randomUUID() : ''
}

/** The snackbar's look for a toast: icon, text key, test id, button. */
export function noteToastView(t: NoteToast) {
  const by: Record<NoteToast['kind'], { icon: UiIconName, text: string, testid: string, button: string }> = {
    archive: { icon: 'archive', text: 'notes.archived_toast', testid: 'notes-archive-toast', button: 'notes.undo' },
    delete: { icon: 'trash', text: 'notes.deleted', testid: 'notes-delete-toast', button: 'notes.undo' },
    discuss: { icon: 'messages', text: 'notes.menu.discussed', testid: 'notes-discuss-toast', button: 'notes.open' },
    failed: { icon: 'x', text: 'notes.not_saved', testid: 'notes-action-failed', button: '' },
  }
  return by[t.kind]
}

type DiscussDeps = { store: ReturnType<typeof useNotesStore>, api: SendApi, live: ReturnType<typeof useLive>, workspace: string }

/** The new topic's id: posted over the live socket, or the mock client's send. */
async function postDiscussion(d: DiscussDeps, text: string): Promise<string> {
  const taskId = newTaskId()
  const sock = d.live.ensure()
  if (sock) {
    const ack = await sock.send({ task_id: taskId, kind: 'note', body: text, files: [], channel: NOTE_DISCUSSION_CHANNEL, is_parent: 1 })
    return String(ack?.task_id || taskId)
  }
  const row = await d.api.sendMessage({ channel: NOTE_DISCUSSION_CHANNEL, text, task_id: taskId || undefined, is_parent: 1 })
  return String(row?.task_id || taskId)
}

/** Turn note `id` into a discussion: its topic id. The note stays and gains a `topic` link to it. */
async function startDiscussion(id: string, d: DiscussDeps): Promise<string> {
  const got = await d.store.get(id)
  const text = 'note' in got ? noteDiscussionBody(got.note) : ''
  if (!text) throw new Error('nothing to post')
  const taskId = await postDiscussion(d, text)
  const label = (text.split('\n')[0] || '').slice(0, 200)
  /* a refused link still leaves the topic */
  if (d.workspace) await d.store.addLink(id, { kind: 'topic', workspace_id: d.workspace, ref: taskId, label }).catch(() => null)
  return taskId
}

/* the page goes (reload, tab closed) or unmounts: a pending DELETE still goes */
function settleOnLeave(settle: (keepalive?: boolean) => void) {
  const onPageHide = () => settle(true)
  onMounted(() => window.addEventListener('pagehide', onPageHide))
  onUnmounted(() => {
    window.removeEventListener('pagehide', onPageHide)
    settle()
  })
}

export function useNoteActions(opts: { onOpenTopic: (taskId: string) => void }) {
  const store = useNotesStore()
  const api = useSpoolApi() as unknown as SendApi
  const live = useLive()
  const note = useAddToNote()
  const toast = ref<NoteToast | null>(null)
  const busy = ref('')
  let seq = 0

  /** The last snackbar ends: a pending DELETE goes (only while the store still holds it: Erase may have sent it). */
  function settle(keepalive = false) {
    const last = toast.value
    toast.value = null
    if (last?.kind === 'delete' && store.hidden.includes(last.id)) void store.remove(last.id, keepalive)
  }
  type ToastIn = NoteToast extends infer T ? (T extends NoteToast ? Omit<T, 'seq'> : never) : never
  const show = (next: ToastIn) => { toast.value = { ...next, seq: ++seq } as NoteToast }

  async function setArchived(id: string, archived: boolean) {
    try {
      await store.patch(id, { archived })
      return true
    } catch {
      show({ kind: 'failed', id })
      return false
    }
  }

  async function archive(id: string) {
    settle()
    if (await setArchived(id, true)) show({ kind: 'archive', id })
  }

  async function unarchive(id: string) {
    settle()
    await setArchived(id, false)
  }

  function remove(id: string) {
    settle()
    const row = store.hide(id)
    if (row) show({ kind: 'delete', id, row })
    else void store.remove(id)
  }

  async function discuss(id: string) {
    settle()
    if (busy.value) return
    busy.value = id
    try {
      show({ kind: 'discuss', id, taskId: await startDiscussion(id, { store, api, live, workspace: note.workspace() }) })
    } catch {
      show({ kind: 'failed', id })
    } finally {
      busy.value = ''
    }
  }

  /** The snackbar's button: Undo an archive or a delete, Open a discussion. */
  async function act() {
    const last = toast.value
    toast.value = null
    if (!last) return
    if (last.kind === 'archive') await setArchived(last.id, false)
    else if (last.kind === 'delete') store.unhide(last.row)
    else if (last.kind === 'discuss') opts.onOpenTopic(last.taskId)
  }

  settleOnLeave(settle)

  return { toast, busy, archive, unarchive, remove, discuss, act, settle }
}
