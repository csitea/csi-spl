import { noteError } from '~/composables/errorJournal.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useTopicStore } from '~/stores/topic'
import { useViewerStore } from '~/stores/viewer'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import type { MoveAnswer, MoveDrag, MoveFrame } from '~/utils/move-apply.mjs'
import { moveHit, sameHit, type MoveHit } from '~/utils/move-drag.mjs'

/** How long "Moved to ... · Undo" stays up (spec 3.3). */
export const MOVE_UNDO_MS = 8000

export type MoveRequest =
  | { kind: 'topic', msgId: string, toChannel: string }
  | { kind: 'message', msgId: string, toTask: string }
  | { kind: 'merge', msgId: string, toTask: string }
  | { kind: 'merge-undo', msgId: string, fromTask: string, msgIds: string[] }
export type MoveToast = { id: number, text: string, undo: MoveRequest | null, busy: boolean }
/* 714c7028: a topic card dropped on another topic asks to MERGE first (the
   whole source topic folds in), so the drop opens a confirm, not the move. */
export type MergeAsk = { msgId: string, toTask: string, sourceTitle: string, targetTitle: string }
type MoveApply = typeof import('~/utils/move-apply.mjs')
export type MovedListener = (f: MoveFrame, m: MoveApply) => void

/* One drag and one toast per tab: the card that starts a drag, the rail row
   or middle card it is dropped on and the toast are different components. */
const drag = shallowRef<MoveDrag | null>(null)
/* SPL-1134: the ONE row under the pointer during a handle drag (null = none) */
const over = shallowRef<MoveHit | null>(null)
let ghost: HTMLElement | null = null
const toast = shallowRef<MoveToast | null>(null)
const mergeAsk = shallowRef<MergeAsk | null>(null)
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
    const move = type === 'topic_moved' || type === 'message_moved'
    const merge = type === 'topic_merged' || type === 'topic_unmerged'
    if (!move && !merge) return
    const m = await loadApply()
    const getTopic = (id: string) => withSessionRetry(api, () => api.getTopic(id, { order: 'desc', limit: 30 }))
    const f = move
      ? m.applyMoveToStores(frame, {
        channel: useChannelStore(), main: useLiveFeed('main'), pane: useLiveFeed('pane'),
        viewer: useViewerStore(), topic: useTopicStore(), getTopic,
      })
      : m.applyMergeToStores(frame, {
        channel: useChannelStore(), main: useLiveFeed('main'), pane: useLiveFeed('pane'),
        viewer: useViewerStore(), getTopic,
      })
    if (f) for (const fn of movedListeners) fn(f as unknown as MoveFrame, m)
  }

  /** The frame type a move / merge answer stands for (applied before the socket copy). */
  function answerFrameType(kind: unknown): string {
    if (kind === 'message') return 'message_moved'
    if (kind === 'merge') return 'topic_merged'
    if (kind === 'unmerge') return 'topic_unmerged'
    return 'topic_moved'
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
    if (req.kind === 'topic') return api.moveTopic(req.msgId, req.toChannel)
    if (req.kind === 'message') return api.moveMessage(req.msgId, req.toTask)
    if (req.kind === 'merge') return api.mergeTopic(req.msgId, req.toTask)
    return api.mergeUndo(req.msgId, req.fromTask, req.msgIds)
  }

  /** The Undo target of a fresh answer, or null: a merge undoes with its whole set. */
  function backOf(req: MoveRequest, answer: MoveAnswer): MoveRequest | null {
    const undo = (answer && answer.undo) as { to_channel?: string, to_task?: string, from_task?: string, msg_ids?: string[] } | undefined
    if (req.kind === 'merge') {
      return undo && undo.from_task ? { kind: 'merge-undo', msgId: req.msgId, fromTask: undo.from_task, msgIds: undo.msg_ids || [] } : null
    }
    if (undo && undo.to_channel) return { kind: 'topic', msgId: req.msgId, toChannel: undo.to_channel }
    if (undo && undo.to_task) return { kind: 'message', msgId: req.msgId, toTask: undo.to_task }
    return null
  }

  /** The toast line for a fresh move / merge; `title` names the target topic. */
  function doneText(req: MoveRequest, answer: MoveAnswer, title: string): string {
    if (req.kind === 'merge') return title ? i18n.t('feed.merge.done', { title }) : i18n.t('feed.merge.done_plain')
    if (req.kind === 'topic') return i18n.t('feed.move.done_channel', { channel: String(answer?.channel || req.toChannel) })
    return title ? i18n.t('feed.move.done_topic', { title }) : i18n.t('feed.move.done_topic_plain')
  }

  async function fail(e: unknown, kind: string = '') {
    const token = (e as { token?: string } | null)?.token
    const m = await loadApply()
    const merge = kind === 'merge' || kind === 'merge-undo'
    const key = merge ? m.mergeErrorKey(e) : m.moveErrorKey(e)
    noteError({ source: 'move', name: merge ? 'Merge' : 'Move', message: i18n.t(key), code: token, error: e })
  }

  /** Move / merge; `title` names the target topic in the toast (a channel names itself). */
  async function run(req: MoveRequest, title = ''): Promise<boolean> {
    drag.value = null
    try {
      const answer = await call(req)
      await dispatch({ ...answer, type: answerFrameType(answer.kind) })
      show(doneText(req, answer, title), backOf(req, answer))
      return true
    } catch (e) {
      await fail(e, req.kind)
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
      await dispatch({ ...answer, type: answerFrameType(answer.kind) })
      show(i18n.t(t.undo.kind === 'merge-undo' ? 'feed.merge.undone' : 'feed.move.undone'), null)
    } catch (e) {
      dismiss()
      await fail(e, t.undo.kind)
    }
  }

  /* 714c7028: a topic card dropped on another topic opens a confirm (the merge
     folds the whole source topic in); MergeConfirmDialog reads mergeAsk. */
  function askMerge(a: MergeAsk) { mergeAsk.value = a }
  function cancelMerge() { mergeAsk.value = null }
  async function confirmMerge(): Promise<boolean> {
    const a = mergeAsk.value
    mergeAsk.value = null
    if (!a) return false
    return run({ kind: 'merge', msgId: a.msgId, toTask: a.toTask }, a.targetTitle)
  }

  /*
   * SPL-1134 (specs/045 §3.9) - the pointer drag from a card's handle. The
   * card feeds the gesture (utils/move-drag.mjs createHandleDrag); this holds
   * the one drag of the tab: the row under the pointer (`over`, read from the
   * element there, so EXACTLY one row can be lit), a small ghost with the
   * title, and the drop. A drop on nothing, or on a row that may not take it,
   * moves nothing.
   */
  function lift(d: MoveDrag, label: string) {
    drag.value = d
    over.value = null
    ghost?.remove()
    ghost = document.createElement('div')
    ghost.className = 'move-ghost'
    ghost.setAttribute('data-testid', 'move-ghost')
    ghost.setAttribute('aria-hidden', 'true')
    ghost.textContent = label.length > 60 ? label.slice(0, 59) + '…' : label
    document.body.appendChild(ghost)
  }

  function track(x: number, y: number) {
    if (!drag.value) return
    if (ghost) ghost.style.transform = `translate(${Math.round(x + 14)}px, ${Math.round(y + 10)}px)`
    const hit = moveHit(document.elementFromPoint(x, y), drag.value)
    if (!sameHit(hit, over.value)) over.value = hit
    if (ghost) ghost.dataset.state = hit ? (hit.ok ? 'ok' : 'denied') : ''
  }

  /** End the drag; `drop` false (Escape, cancel) moves nothing. */
  function land(drop: boolean) {
    const d = drag.value
    const hit = over.value
    over.value = null
    drag.value = null
    ghost?.remove()
    ghost = null
    if (!drop || !d || !hit || !hit.ok) return
    if (d.kind === 'topic' && hit.kind === 'channel') void run({ kind: 'topic', msgId: d.msgId, toChannel: hit.id })
    else if (d.kind === 'topic' && hit.kind === 'card') askMerge({ msgId: d.msgId, toTask: hit.id, sourceTitle: d.title || '', targetTitle: hit.title })
    else if (d.kind === 'message' && hit.kind === 'card') void run({ kind: 'message', msgId: d.msgId, toTask: hit.id }, hit.title)
  }

  return { drag, over, toast, mergeAsk, dispatch, onMoved, run, undo, dismiss, lift, track, land, askMerge, cancelMerge, confirmMerge }
}
