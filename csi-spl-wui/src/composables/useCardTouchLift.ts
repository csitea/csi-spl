/*
 * HUM-10 (owner, t1 5a410ad5): "One should be able to drag and drop topics
 * into other topics on mobile as well." On a phone a long press on a topic
 * card the viewer may move LIFTS it (a buzz, the ghost): the finger drags it
 * over another topic card, which lights, and the list scrolls while the finger
 * is near its top or bottom edge. The release is the desktop drop (move.land):
 * the same Merge confirm, the same merge call, the same Undo. A finger that
 * moves before the hold is a scroll (move-drag.mjs slop) and lifts nothing; a
 * hold released where it was opens the card menu, as the long press always
 * did (Merge into topic… there is the way that needs no drag). The 12 px
 * handle keeps opening Move to channel… (the rail is not beside the list).
 * (MessageCard, split out in r13-01.)
 */
import { computed, onBeforeUnmount, watch, type Ref } from 'vue'
import { LONG_PRESS_MS, LONG_PRESS_SLOP_PX } from '~/utils/touch-ui.mjs'
import { createEdgeScroll, createHandleDrag } from '~/utils/move-drag.mjs'
import { useMobileStack } from '~/composables/useMobileStack'
import { buzz } from '~/composables/useCardSwipe'
import type { useCardMove } from '~/composables/useCardMove'
import type { CardMenu } from '~/composables/useCardReactions'

type Move = ReturnType<typeof useCardMove>['flags']['move']

function scrollBox(rowEl: Ref<HTMLElement | null>): HTMLElement | null {
  for (let e = rowEl.value?.parentElement; e; e = e.parentElement) {
    const oy = getComputedStyle(e).overflowY
    if ((oy === 'auto' || oy === 'scroll') && e.scrollHeight > e.clientHeight) return e
  }
  return (document.scrollingElement as HTMLElement | null) || null
}

/** The list scrolls while a lifted card is near its top or bottom edge;
    `setBox` names the list (null when the lift ends). */
function useEdgeScroll(move: Move) {
  let edgeBox: HTMLElement | null = null
  const edgeScroll = createEdgeScroll({
    box: () => {
      const b = edgeBox
      if (!b) return null
      const whole = b === document.scrollingElement
      const r = whole ? { top: 0, bottom: window.innerHeight } : b.getBoundingClientRect()
      return {
        top: r.top,
        bottom: r.bottom,
        scrollBy: (dy: number) => {
          const before = b.scrollTop
          b.scrollTop = before + dy
          return b.scrollTop !== before
        },
      }
    },
    onScroll: (x, y) => move.track(x, y),
  })
  const setBox = (b: HTMLElement | null) => { edgeBox = b }
  return [edgeScroll, setBox] as const
}

/** `stopOthers` cancels the card's long press and swipe when the card lifts. */
export function useCardTouchLift(rowEl: Ref<HTMLElement | null>, editing: Ref<boolean>, mv: ReturnType<typeof useCardMove>, stopOthers: () => void, pickerOpen: Ref<boolean>, menu: CardMenu) {
  const { move, canMoveTopic } = mv.flags
  const { close: closeMenu, openAt: openMenuAt } = menu
  const stack = useMobileStack()
  const touchLift = computed(() => stack.isMobile.value && canMoveTopic.value && !editing.value)
  let liftAt = { x: 0, y: 0 }
  let liftTravel = false
  const [edgeScroll, setBox] = useEdgeScroll(move)
  function endTouchDrag() {
    edgeScroll.stop()
    setBox(null)
    mv.endDrag()
  }
  const rowDrag = createHandleDrag({
    holdMs: LONG_PRESS_MS,
    slopPx: LONG_PRESS_SLOP_PX,
    onStart: (x, y) => {
      stopOthers()
      stack.swipe.claim()
      closeMenu()
      pickerOpen.value = false
      buzz()
      liftAt = { x, y }
      liftTravel = false
      setBox(scrollBox(rowEl))
      mv.liftCard(x, y)
    },
    onMove: (x, y) => {
      if (!liftTravel && Math.hypot(x - liftAt.x, y - liftAt.y) > LONG_PRESS_SLOP_PX) liftTravel = true
      if (liftTravel) edgeScroll.at(x, y)
      move.track(x, y)
    },
    onDrop: (x, y) => {
      endTouchDrag()
      if (!liftTravel) {
        move.land(false)
        rowEl.value?.focus({ preventScroll: true })
        openMenuAt(liftAt.x, liftAt.y)
        return
      }
      move.track(x, y)
      move.land(true)
    },
    onCancel: () => {
      endTouchDrag()
      move.land(false)
    },
  })
  useLiftListeners(touchLift, rowEl, rowDrag)
  return { touchLift, rowDrag }
}

/* the page must not scroll under a lifted card: a touchmove the browser may
   still cancel is cancelled (not passive, so only on the rows that lift) */
function useLiftListeners(touchLift: Ref<boolean>, rowEl: Ref<HTMLElement | null>, rowDrag: ReturnType<typeof createHandleDrag>) {
  function onLiftTouchMove(ev: TouchEvent) {
    if (rowDrag.state === 'lifted' && ev.cancelable) ev.preventDefault()
  }
  /* the click the release sends opens nothing: not the topic, and not a button
     the finger happened to hold (the menu button would close the menu again) */
  function onLiftClick(ev: MouseEvent) {
    if (!rowDrag.takeClick()) return
    ev.preventDefault()
    ev.stopPropagation()
  }
  let liftListenerOn: HTMLElement | null = null
  watch([touchLift, rowEl], ([on, el]) => {
    if (liftListenerOn && (!on || liftListenerOn !== el)) {
      liftListenerOn.removeEventListener('touchmove', onLiftTouchMove)
      liftListenerOn.removeEventListener('click', onLiftClick, true)
      liftListenerOn = null
    }
    if (on && el && !liftListenerOn) {
      el.addEventListener('touchmove', onLiftTouchMove, { passive: false })
      el.addEventListener('click', onLiftClick, true)
      liftListenerOn = el
    }
  }, { immediate: true, flush: 'post' })
  onBeforeUnmount(() => {
    rowDrag.cancel()
    liftListenerOn?.removeEventListener('touchmove', onLiftTouchMove)
    liftListenerOn?.removeEventListener('click', onLiftClick, true)
    liftListenerOn = null
  })
}
