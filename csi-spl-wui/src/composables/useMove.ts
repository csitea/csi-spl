import { noteError } from '~/composables/errorJournal.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useTopicStore } from '~/stores/topic'
import { useViewerStore } from '~/stores/viewer'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import type { MoveAnswer, MoveDrag, MoveFrame } from '~/utils/move-apply.mjs'

/** How long "Moved to ... · Undo" stays up (spec 3.3). */
export const MOVE_UNDO_MS = 8000

export type MoveRequest = { kind: 'topic', msgId: string, toChannel: string } | { kind: 'message', msgId: string, toTask: string }
export type MoveToast = { id: number, text: string, undo: MoveRequest | null, busy: boolean }
type MoveApply = typeof import('~/utils/move-apply.mjs')
export type MovedListener = (f: MoveFrame, m: MoveApply) => void

/* One drag and one toast per tab: the card that starts a drag, the rail row
   or middle card it is dropped on and the toast are different components. */
const drag = shallowRef<MoveDrag | null>(null)
const toast = shallowRef<MoveToast | null>(null)
const movedListeners = new Set<MovedListener>()
let toastSeq = 0
let toastTimer: ReturnType<typeof setTimeout> | null = null

/** The move logic itself loads on the first move or move frame (specs/027 initial-JS budget). */
const loadApply = () => import('~/utils/move-apply.mjs')

/**
 * SPL-1024 (specs/045) - move a topic to a channel, a reply to a topic.
 *
 * `run` is the one call every gesture ends in (a rail drop, a card drop, the
 * picker): POST .../move, then the answer is applied to every store at once
 * (the hub's frame for this tab arrives later and changes nothing more), and
 * the toast offers Undo for 8 s. A refusal goes to the error snackbar with
 * the hub's token. `dispatch` is what the shell calls for another tab's frame.
 */
export function useMove() {
  const api = useSpoolApi()
  const i18n = useNuxtApp().$i18n

  async function dispatch(frame: unknown) {
    const type = (frame as { type?: string } | null)?.type
    if (type !== 'topic_moved' && type !== 'message_moved') return
    const m = await loadApply()
    const f = m.applyMoveToStores(frame, {
      channel: useChannelStore(),
      main: useLiveFeed('main'),
      pane: useLiveFeed('pane'),
      viewer: useViewerStore(),
      topic: useTopicStore(),
      getTopic: (id: string) => withSessionRetry(api, () => api.getTopic(id, { order: 'desc', limit: 30 })),
    })
    if (f) for (const fn of movedListeners) fn(f, m)
  }

  /** A pane that holds rows of its own (TopicPane) hears every move here. */
  function onMoved(fn: MovedListener) {
    movedListeners.add(fn)
    return () => movedListeners.delete(fn)
  }

  function dismiss() {
    if (toastTimer) clearTimeout(toastTimer)
    toastTimer = null
    toast.value = null
  }

  function show(text: string, undo: MoveRequest | null) {
    if (toastTimer) clearTimeout(toastTimer)
    const id = ++toastSeq
    toast.value = { id, text, undo, busy: false }
    toastTimer = setTimeout(() => { if (toast.value && toast.value.id === id) dismiss() }, undo ? MOVE_UNDO_MS : 3000)
  }

  function call(req: MoveRequest): Promise<MoveAnswer> {
    return req.kind === 'topic' ? api.moveTopic(req.msgId, req.toChannel) : api.moveMessage(req.msgId, req.toTask)
  }

  async function fail(e: unknown) {
    const token = (e as { token?: string } | null)?.token
    const { moveErrorKey } = await loadApply()
    noteError({ source: 'move', name: 'Move', message: i18n.t(moveErrorKey(e)), code: token, error: e })
  }

  /** Move; `title` names the target topic in the toast (a channel names itself). */
  async function run(req: MoveRequest, title = ''): Promise<boolean> {
    drag.value = null
    try {
      const answer = await call(req)
      await dispatch({ ...answer, type: answer.kind === 'message' ? 'message_moved' : 'topic_moved' })
      const undo = answer && answer.undo
      const back: MoveRequest | null = undo && undo.to_channel
        ? { kind: 'topic', msgId: req.msgId, toChannel: undo.to_channel }
        : undo && undo.to_task ? { kind: 'message', msgId: req.msgId, toTask: undo.to_task } : null
      const text = req.kind === 'topic'
        ? i18n.t('feed.move.done_channel', { channel: String(answer?.channel || req.toChannel) })
        : (title ? i18n.t('feed.move.done_topic', { title }) : i18n.t('feed.move.done_topic_plain'))
      show(text, back)
      return true
    } catch (e) {
      await fail(e)
      return false
    }
  }

  /** The toast's Undo: the same endpoint, the answer's `undo` as the target. */
  async function undo() {
    const t = toast.value
    if (!t || !t.undo || t.busy) return
    toast.value = { ...t, busy: true }
    try {
      const answer = await call(t.undo)
      await dispatch({ ...answer, type: answer.kind === 'message' ? 'message_moved' : 'topic_moved' })
      show(i18n.t('feed.move.undone'), null)
    } catch (e) {
      dismiss()
      await fail(e)
    }
  }

  return { drag, toast, dispatch, onMoved, run, undo, dismiss }
}
