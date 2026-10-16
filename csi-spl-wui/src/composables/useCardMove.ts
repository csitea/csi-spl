/*
 * SPL-1024 / SPL-1134 (specs/045 §3.9) — move by drag (MessageCard, split
 * out in r13-01). A middle card the viewer may move (author / tenant owner /
 * admin, a channel topic) drags onto a left-rail channel; a thread row they
 * may move drags onto another middle card. The drag starts ONLY from the
 * handle strip (the card's first ~3 mm): a mouse after 4 px of travel, a
 * finger after a hold. A phone has no rail beside the list, so there the hold
 * opens Move to … instead. The row under the pointer is found by useMove (one
 * row lit at a time).
 */
import { computed, onBeforeUnmount, ref, type Ref } from 'vue'
import { isCardDropTarget, isMergeCardDropTarget, mayMoveMessage, mayMoveTopic, mayPromoteMessage, type MoveDrag } from '~/utils/move.mjs'
import { createHandleDrag } from '~/utils/move-drag.mjs'
import { topicMenuLocks } from '~/utils/topic-menu.mjs'
import { useMove } from '~/composables/useMove'
import { useLive } from '~/composables/useLive'
import { useMobileStack } from '~/composables/useMobileStack'
import { buzz } from '~/composables/useCardSwipe'
import type { CardMenu } from '~/composables/useCardReactions'
import type { useAccessStore } from '~/stores/access'
import type { SpoolMessage } from '~/types/spool'

export interface CardMoveProps {
  msg: SpoolMessage
  topicMenu?: boolean
  editable?: boolean
  moveCtx?: { channel?: string | null, opener?: string, topic?: string } | null
}

/** What this viewer may move from this card, and whether a drag may land on it. */
export function useCardMoveFlags(props: CardMoveProps, editing: Ref<boolean>, inTopicPane: Ref<boolean>, editorId: Ref<string>, access: ReturnType<typeof useAccessStore>) {
  const move = useMove()
  const lobbyTask = useLive().lobbyTaskId
  /* the thread row's place, as mayMoveMessage and mayPromoteMessage read it */
  const rowPlace = () => ({
    openerId: props.moveCtx?.opener || '',
    lobbyTaskId: lobbyTask.value,
    channel: props.moveCtx?.channel || '',
  })
  const canMoveTopic = computed(() => Boolean(props.topicMenu) && mayMoveTopic(props.msg, editorId.value, access.me, lobbyTask.value))
  const canMoveMsg = computed(() => Boolean(props.moveCtx) && !props.topicMenu && mayMoveMessage(props.msg, editorId.value, access.me, rowPlace()))
  /* a DM row an agent sent may move out to a channel topic, never become a topic of its own */
  const canPromoteMsg = computed(() => canMoveMsg.value && mayPromoteMessage(props.msg, editorId.value, access.me, rowPlace()))
  const movable = computed(() => {
    if (editing.value) return false
    /* A reply drags out of the thread. A topic drags from the middle card
       only: the opener in the open discussion keeps Move in the menu and
       does not grow a second handle (spec 045, the opening card has none). */
    if (canMoveMsg.value) return true
    if (inTopicPane.value) return false
    return canMoveTopic.value
  })
  /* CLE-77891 (HUM-24): a topic card's menu has the same entries for everyone;
     what this viewer may not do is shown disabled with the reason. */
  const menuLocks = computed(() => props.topicMenu && !editing.value
    ? topicMenuLocks(props.msg, editorId.value, access.me, { editable: Boolean(props.editable), lobbyTaskId: lobbyTask.value })
    : undefined)
  const dropTarget = computed(() => Boolean(props.topicMenu) && (isCardDropTarget(move.drag.value, props.msg, lobbyTask.value) || isMergeCardDropTarget(move.drag.value, props.msg, lobbyTask.value)))
  const dropOver = computed(() => {
    const o = move.over.value
    return Boolean(o && o.kind === 'card' && o.ok && o.id === String(props.msg.task_id || ''))
  })
  return { move, canMoveTopic, canMoveMsg, canPromoteMsg, movable, menuLocks, dropTarget, dropOver }
}

/** `peer.swipeDown` starts the card's swipe from the handle (a thumb's swipe
    often starts on the edge); `peer.cancelRowDrag` drops a phone's touch lift. */
export function useCardMove(
  props: CardMoveProps,
  flags: ReturnType<typeof useCardMoveFlags>,
  title: Ref<string>,
  pickerOpen: Ref<boolean>,
  menu: CardMenu,
  peer: { swipeDown: (ev: PointerEvent) => void, cancelRowDrag: () => void },
) {
  const { move, canMoveTopic, movable } = flags
  const { close: closeMenu } = menu
  const mobile = useMobileStack().isMobile
  const dragging = ref(false)
  const { movePicker, openMovePicker, onPromote } = useMovePickers(props, move, closeMenu)

  function moveDrag(): MoveDrag {
    const m = props.msg
    return canMoveTopic.value
      ? { kind: 'topic', msgId: String(m.msg_id), taskId: String(m.task_id || ''), topicTask: String(m.task_id || ''), channel: String(m.channel || ''), title: title.value || String(m.body || '').slice(0, 60) }
      : { kind: 'message', msgId: String(m.msg_id), taskId: String(m.task_id || ''), topicTask: String(props.moveCtx?.topic || ''), channel: String(m.channel || props.moveCtx?.channel || '') }
  }
  function onMoveKey(ev: KeyboardEvent) {
    if (ev.key !== 'Escape') return
    ev.preventDefault()
    handle.cancel()
    peer.cancelRowDrag()
  }
  function endDrag() {
    dragging.value = false
    window.removeEventListener('keydown', onMoveKey, true)
  }
  /** a drag lifts this card: the ghost follows the pointer, Escape drops it */
  function liftCard(x: number, y: number) {
    dragging.value = true
    window.addEventListener('keydown', onMoveKey, true)
    move.lift(moveDrag(), title.value || String(props.msg.body || '').slice(0, 60))
    move.track(x, y)
  }
  const handle = createHandleDrag({
    onStart: (x, y) => {
      closeMenu()
      pickerOpen.value = false
      liftCard(x, y)
    },
    onMove: (x, y) => move.track(x, y),
    onDrop: (x, y) => {
      move.track(x, y)
      endDrag()
      move.land(true)
    },
    onCancel: () => {
      endDrag()
      move.land(false)
    },
    onHold: () => {
      if (!mobile.value) return true
      buzz()
      openMovePicker(canMoveTopic.value ? 'channel' : 'topic')
      return false
    },
  })
  function onHandleDown(ev: PointerEvent) {
    /* CLE-77906: a thumb's swipe often starts on the card's edge, which is this
       handle; the handle stops the row's pointerdown, so start it here. A finger
       that moves before the hold is not a move-drag (move-drag.mjs slop), so the
       two never both run. */
    peer.swipeDown(ev)
    if (!movable.value || !handle.down(ev)) return
    /* no text selection, no native drag, and the stream stays on the handle
       wherever the pointer goes */
    ev.preventDefault()
    const el = ev.currentTarget as HTMLElement | null
    try { el?.setPointerCapture(ev.pointerId) } catch { /* the pointer is gone already */ }
  }
  function onHandleUp(ev: PointerEvent) {
    handle.up(ev)
    handle.takeClick()
  }
  onBeforeUnmount(() => handle.cancel())
  return { flags, dragging, movePicker, liftCard, endDrag, handle, onHandleDown, onHandleUp, openMovePicker, onPromote }
}

/** Move to channel… / Move to topic… / Merge into topic…, and Make it a topic. */
function useMovePickers(props: CardMoveProps, move: ReturnType<typeof useMove>, closeMenu: () => void) {
  const movePicker = ref<'' | 'channel' | 'topic' | 'merge'>('')
  function openMovePicker(mode: 'channel' | 'topic' | 'merge') {
    closeMenu()
    movePicker.value = mode
  }
  /* 8f588edd: "Make it a topic" - the keyboard / touch way to promote this reply
     into a new topic of its own, what the drag into the topics list does. */
  function onPromote() {
    closeMenu()
    void move.run({ kind: 'promote', msgId: String(props.msg.msg_id || '') })
  }
  return { movePicker, openMovePicker, onPromote }
}
