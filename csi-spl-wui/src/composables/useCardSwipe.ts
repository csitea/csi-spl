/*
 * MessageCard's touch gestures (r13-01): the long press and the swipe.
 *
 * SPL-991 — a phone has no hover and no right-click: a long press opens the
 * card's menu as a bottom sheet (utils/touch-ui.mjs holds the timing rule).
 * Android also fires `contextmenu` on a long press; both open the same menu.
 *
 * CLE-77906 (owner, t1 topic 73c5d695) archived a topic by a swipe right;
 * HUM-10 (owner, t1 topic 2d09e9c2, 2026-10-03): "Let's change the swipe left
 * to do the archiving and let's change the swipe right to actually show the
 * right-click menu." A finger sliding a topic card (cards view) or the
 * topic's opening message (topic view) to the LEFT archives the topic through
 * the menu's own Archive (onMenuArchive: the same permission, the same
 * "Archived · Undo" snackbar with its touch window). A finger sliding any card
 * to the RIGHT opens its menu, the one a right-click opens (openMenuAt). A
 * right swipe that starts in the phone's Back zone (the left half, while there
 * is a level to go back to) is not the card's: it stays the shell's Back
 * (useMobileStack), exactly as before. The rules of the gesture are
 * utils/swipe-archive.mjs; a mouse never swipes, so the desktop card is
 * unchanged. While it slides the card moves and the strip it uncovers shows
 * the archive (or menu) icon; short of the threshold the card snaps back. A
 * swipe takes the gesture from the long press.
 */
import { computed, nextTick, onBeforeUnmount, onMounted, ref, type Ref } from 'vue'
import { createLongPress } from '~/utils/touch-ui.mjs'
import { SWIPE_SETTLE_MS, createSwipe, swipeInBackZone, swipeLeftAction } from '~/utils/swipe-archive.mjs'
import { paneOfRow } from '~/utils/reselect-row.mjs'
import { isTouchUi } from '~/utils/undo-timer'
import { useHiddenCards } from '~/composables/useHiddenCards'
import { useMobileStack } from '~/composables/useMobileStack'
import { useLiveFeed } from '~/stores/live'
import { useTopicStore } from '~/stores/topic'
import type { CardMenu } from '~/composables/useCardReactions'
import type { SpoolMessage } from '~/types/spool'

/** a short buzz where the device has one: the gesture took */
export function buzz() {
  if (typeof navigator !== 'undefined' && typeof navigator.vibrate === 'function') navigator.vibrate(10)
}

export function useCardLongPress(editing: Ref<boolean>, pickerOpen: Ref<boolean>, menu: CardMenu) {
  const { openAt: openMenuAt } = menu
  const longPress = createLongPress({
    onPress: (x, y) => {
      if (editing.value) return
      pickerOpen.value = false
      buzz()
      openMenuAt(x, y)
    },
  })
  onBeforeUnmount(() => longPress.cancel())
  return longPress
}

type SwipeProps = { msg: SpoolMessage, topicMenu?: boolean, moveCtx?: { opener?: string } | null }

/** Which way this card may swipe, and what a left swipe does. `mayArchive`
    is the topic-view rule for a card that is neither a topic card nor in a pane. */
export function useCardSwipeFlags(props: SwipeProps, editing: Ref<boolean>, rowEl: Ref<HTMLElement | null>, inPane: Ref<boolean>, showTopicArchive: Ref<boolean>, mayArchive: () => boolean) {
  const mobile = useMobileStack().isMobile
  const touchUi = ref(false)
  /* the topic view (the right pane, channel or DM): its level-1 row is the
     topic's own message (the pane opened by task id has no rootMsgId to match) */
  const inTopicPane = ref(false)
  onMounted(() => {
    touchUi.value = isTouchUi()
    inTopicPane.value = paneOfRow(rowEl.value) === 'topic'
  })
  /** the card swipes at all (a right swipe opens its menu) */
  const swipeOn = computed(() => !editing.value && (mobile.value || touchUi.value))
  /** ... and a left swipe archives its topic */
  const swipeArchive = computed(() => {
    if (!swipeOn.value) return false
    if (props.topicMenu || inPane.value) return showTopicArchive.value
    return inTopicPane.value && mayArchive()
  })
  /* HUM-10 (owner, t1 topics 6fc56905 / 3e073a95): in the topic view a reply's
     LEFT swipe hides it on this device (useHiddenCards; not archive, not
     delete): LiveFeed puts a thicker line where it was and a tap on the line
     shows it again. The topic starter (a topic card, any level-1 row, the
     pane's opener) keeps the archive and is never hidden (swipeLeftAction). */
  const swipeStarter = computed(() => Boolean(props.topicMenu) || props.msg.is_parent !== 0
    || (Boolean(props.moveCtx?.opener) && props.msg.msg_id === props.moveCtx?.opener))
  const swipeLeft = computed(() => {
    /* HUM-10: the pane's latest reply archives the topic instead of hiding */
    const starter = swipeStarter.value || (inPane.value && swipeArchive.value)
    const a = swipeLeftAction({ swipeOn: swipeOn.value, starter, mayArchive: swipeArchive.value, inTopicPane: inTopicPane.value })
    return a === 'hide' && (!props.msg.msg_id || props.msg.pending) ? null : a
  })
  /* HUM-10 (owner, t1 7d9faaad): the right-click menu, the … button and the
     phone's swipe-right sheet offer Hide from flow where a left swipe would
     hide this reply. swipeOn is forced on: a desktop card does not swipe, and
     the allow-rule is still a topic-view reply (not the starter) with a
     msg_id that is not pending. feed.swipe_hide stays the gesture hint. */
  const menuHide = computed(() => Boolean(props.msg.msg_id) && !props.msg.pending
    && swipeLeftAction({ swipeOn: true, starter: swipeStarter.value, mayArchive: swipeArchive.value, inTopicPane: inTopicPane.value }) === 'hide')
  return { inTopicPane, swipeOn, swipeArchive, swipeLeft, menuHide }
}

/** The slide itself: where the card is, and whether it animates there. */
function useSwipeSlide() {
  /** signed: < 0 slid towards the start (archive / hide), > 0 towards the end (menu) */
  const swipeDx = ref(0)
  const swipeDir = ref<'archive' | 'hide' | 'menu'>('archive')
  const swipeArmed = ref(false)
  /** the snap back / the slide out animates; a finger-driven move does not */
  const swipeSettle = ref(false)
  let settleTimer: ReturnType<typeof setTimeout> | null = null
  function swipeTo(dx: number, settle: boolean) {
    if (settleTimer) clearTimeout(settleTimer)
    settleTimer = null
    swipeSettle.value = settle
    swipeDx.value = dx
    /* the transform must not outlive the animation: a transformed card is the
       containing block of its fixed menus and pickers */
    if (settle && dx === 0) settleTimer = setTimeout(() => { swipeSettle.value = false; settleTimer = null }, SWIPE_SETTLE_MS)
  }
  onBeforeUnmount(() => { if (settleTimer) clearTimeout(settleTimer) })
  return { swipeDx, swipeDir, swipeArmed, swipeSettle, swipeTo }
}

/** `peer.stop` cancels the card's other gestures (long press, touch lift);
    `peer.archive` is the menu's Archive topic, true when it archived. */
export function useCardSwipe(
  props: { msg: SpoolMessage, topicMenu?: boolean },
  rowEl: Ref<HTMLElement | null>,
  swipeLeft: Ref<ReturnType<typeof swipeLeftAction> | null>,
  pickerOpen: Ref<boolean>,
  menu: CardMenu,
  peer: { stop: () => void, archive: () => Promise<boolean> },
) {
  const stack = useMobileStack()
  const slide = useSwipeSlide()
  const { openAt: openMenuAt } = menu
  const { swipeDir, swipeArmed, swipeTo } = slide
  const commits = useSwipeCommits(props, rowEl, menu, peer.archive, slide)
  const swipeRtl = () => typeof document !== 'undefined' && document.documentElement.dir === 'rtl'
  const swipe = createSwipe({
    width: () => rowEl.value?.getBoundingClientRect().width || 0,
    rtl: swipeRtl,
    leftDir: () => swipeLeft.value,
    /* the Back zone wins: a right swipe from there is the shell's Back */
    canRight: (x) => !(stack.isMobile.value && stack.level.value > 1
      && swipeInBackZone(x, typeof window !== 'undefined' ? window.innerWidth : 0, swipeRtl())),
    onLock: (dir) => {
      peer.stop()
      swipeDir.value = dir
    },
    onMove: (dx, armed, dir) => {
      if (armed && !swipeArmed.value) buzz()
      swipeArmed.value = armed
      swipeTo(dir === 'menu' ? dx : -dx, false)
    },
    onCommit: (dir, x, y) => {
      if (dir === 'archive') return void commits.swipeCommit()
      if (dir === 'hide') return void commits.swipeHideCommit()
      swipeArmed.value = false
      /* no slide back first: a transformed card would hold the menu */
      swipeTo(0, false)
      pickerOpen.value = false
      rowEl.value?.focus({ preventScroll: true })
      openMenuAt(x, y)
    },
    onCancel: () => {
      swipeArmed.value = false
      swipeTo(0, true)
    },
  })
  onBeforeUnmount(() => swipe.cancel())
  return { swipe, ...slide, onMenuHide: commits.onMenuHide }
}

/** A swipe past the threshold: archive the topic, or hide this reply. */
function useSwipeCommits(props: { msg: SpoolMessage, topicMenu?: boolean }, rowEl: Ref<HTMLElement | null>, menu: CardMenu, onMenuArchive: () => Promise<boolean>, slide: ReturnType<typeof useSwipeSlide>) {
  const { swipeArmed, swipeTo } = slide
  const stack = useMobileStack()
  const { close: closeMenu } = menu
  const hiddenCards = useHiddenCards()
  async function swipeCommit() {
    stack.swipe.claim()
    const inTopicPane = paneOfRow(rowEl.value) === 'topic'
    swipeTo(-(rowEl.value?.getBoundingClientRect().width || 0), true)
    const ok = await onMenuArchive()
    swipeArmed.value = false
    if (!ok) {
      swipeTo(0, true)
      return
    }
    swipeTo(0, false)
    /* the topic view of a topic that is archived now: back to the cards, where
       the snackbar's Undo brings the card back (and selects it) */
    if (inTopicPane && !props.topicMenu) {
      useLiveFeed('pane').close()
      useTopicStore().close()
    }
  }
  /* the card slides out, then leaves the list: LiveFeed draws the line */
  let hideTimer: ReturnType<typeof setTimeout> | null = null
  function onMenuHide() {
    closeMenu()
    swipeHideCommit()
  }
  function swipeHideCommit() {
    stack.swipe.claim()
    swipeTo(-(rowEl.value?.getBoundingClientRect().width || 0), true)
    if (hideTimer) clearTimeout(hideTimer)
    hideTimer = setTimeout(() => {
      hideTimer = null
      swipeArmed.value = false
      hiddenCards.hide(String(props.msg.msg_id || ''))
      /* a list that does not fold hidden rows keeps the card: slide it back */
      void nextTick(() => { if (rowEl.value?.isConnected) swipeTo(0, true) })
    }, SWIPE_SETTLE_MS)
  }
  onBeforeUnmount(() => { if (hideTimer) clearTimeout(hideTimer) })
  return { swipeCommit, swipeHideCommit, onMenuHide }
}
