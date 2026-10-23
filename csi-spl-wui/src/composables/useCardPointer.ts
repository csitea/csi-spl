/*
 * MessageCard's pointer, click and context-menu routing (r19-04, split out of
 * the card like r13-01's parts): which part of the card a press, a click, a
 * right-click or a double-click belongs to. The parts themselves (long press,
 * swipe, touch lift, menu, edit) stay in their own composables; this only
 * routes the row's events between them.
 */
import type { Ref } from 'vue'
import { wantsDblClickEdit } from '~/utils/msg-edit.mjs'
import type { CardMenu } from '~/composables/useCardReactions'
import type { useCardLongPress, useCardSwipe } from '~/composables/useCardSwipe'
import type { useCardTouchLift } from '~/composables/useCardTouchLift'
import type { SpoolMessage } from '~/types/spool'

type TouchLift = ReturnType<typeof useCardTouchLift>

/** What the card hands its pointer routing: the row, its edit state, its menu and its gestures. */
interface CardPointerDeps {
  props: { msg: SpoolMessage, clickable?: boolean, editable?: boolean }
  emit: (e: 'open-topic', msg: SpoolMessage) => void
  rowEl: Ref<HTMLElement | null>
  editing: Ref<boolean>
  startEdit: () => void
  pickerOpen: Ref<boolean>
  menu: CardMenu
  longPress: ReturnType<typeof useCardLongPress>
  swipe: ReturnType<typeof useCardSwipe>['swipe']
  rowDrag: TouchLift['rowDrag']
  touchLift: TouchLift['touchLift']
  swipeDown: (ev: PointerEvent) => void
}

/*
 * clicking the row opens its topic. The row already carried
 * tabindex="0" for the feed pattern, so the keyboard half is Enter / Space on
 * the focused row; the explicit "open topic" icon button stays as the
 * discoverable, screen-reader-named affordance.
 *
 * Two things a whole-row click must not eat: a click on something that is
 * itself interactive (a link in the body, the copy-code button, a file
 * attachment, the reply-count button — those handle themselves), and the
 * click that ENDS a text selection inside the message, which is how a reader
 * copies a line and never means "open the topic".
 */
const INTERACTIVE = 'a, button, input, textarea, select, label, summary, [role="button"], [contenteditable="true"]'

function selecting() {
  const sel = typeof window !== 'undefined' ? window.getSelection() : null
  return Boolean(sel && !sel.isCollapsed && String(sel).trim())
}

const MENU_PASS = 'a, button, input, textarea, select'

/*
 * HUM-10 (owner, t1 86698d8a): on a phone a thumb held on the card's TEXT is
 * the browser's own long press: it selects a word, with handles and the
 * native copy pop-up, so part of a message can be copied. The text is the
 * one selectable part of the card (MessageCard.vue's CSS); the card's own
 * long press (the menu, or the topic lift) stays on the rest of it, and the
 * ⋯ button opens the menu from anywhere.
 */
const TEXT_SELECT = '.msg-body'

/** The row's pointer events and its right-click: which gesture a finger or a mouse starts. */
export function useCardRowPointer(d: Pick<CardPointerDeps, 'rowEl' | 'editing' | 'menu' | 'longPress' | 'swipe' | 'rowDrag' | 'touchLift' | 'swipeDown'>) {
  const { rowEl, editing, longPress, swipe, rowDrag, touchLift, swipeDown } = d
  const { openAt: openMenuAt } = d.menu
  let touchOnText = false
  function onTextTouch(ev: PointerEvent): boolean {
    const el = ev.target as HTMLElement | null
    touchOnText = ev.pointerType === 'touch' && !editing.value && Boolean(el?.closest?.(TEXT_SELECT))
    return touchOnText
  }

  function onContextMenu(ev: MouseEvent) {
    /* HUM-10 (86698d8a): the browser's selection pop-up, not the card menu */
    if (touchOnText) return
    /* HUM-10: Android's long press fires contextmenu while the finger is still
       on a card it may lift; the hold (or its release in place) decides */
    if (rowDrag.state !== 'idle') {
      ev.preventDefault()
      return
    }
    const el = ev.target as HTMLElement | null
    if (el && el.closest && el.closest(MENU_PASS) && !el.closest('[data-testid="msg-menu-btn"]')) return
    ev.preventDefault()
    rowEl.value?.focus({ preventScroll: true })
    openMenuAt(ev.clientX, ev.clientY)
  }

  function onRowDown(ev: PointerEvent) {
    /* HUM-10: a finger on a topic card it may move lifts it on the hold (the
       long-press menu then opens on a release in place, see rowDrag) */
    if (onTextTouch(ev)) longPress.cancel()
    else if (touchLift.value && ev.pointerType === 'touch') rowDrag.down(ev)
    else longPress.down(ev)
    swipeDown(ev)
  }
  function onRowMove(ev: PointerEvent) {
    rowDrag.move(ev)
    if (rowDrag.state === 'lifted') return
    longPress.move(ev)
    swipe.move(ev)
  }
  function onRowUp(ev: PointerEvent) {
    rowDrag.up(ev)
    longPress.up()
    swipe.up()
  }
  function onRowCancel() {
    rowDrag.cancel()
    longPress.cancel()
    swipe.cancel()
  }
  return { onContextMenu, onRowDown, onRowMove, onRowUp, onRowCancel }
}

/** The row's clicks: open the topic, open the menu from its button, edit on a double-click. */
export function useCardClick(d: Pick<CardPointerDeps, 'props' | 'emit' | 'rowEl' | 'editing' | 'startEdit' | 'pickerOpen' | 'menu' | 'longPress' | 'swipe'>) {
  const { props, emit, rowEl, editing, startEdit, pickerOpen, longPress, swipe } = d
  const { open: menuOpen, openAt: openMenuAt, close: closeMenu } = d.menu
  function onClick(ev: MouseEvent) {
    /* SPL-991: the finger that long-pressed lifts with a click; it opened the
       menu and must not also open the topic */
    if (longPress.takeClick()) {
      ev.preventDefault()
      return
    }
    /* CLE-77906: nor does the finger that swiped */
    if (swipe.takeClick()) {
      ev.preventDefault()
      return
    }
    const el = ev.target as HTMLElement | null
    if (el && el.closest && el.closest(INTERACTIVE)) return
    if (selecting()) return
    /* A thread row is not clickable. The click selects it, so Delete and e
       apply to this message. A clickable row still opens its topic. */
    if (!props.clickable) {
      rowEl.value?.focus({ preventScroll: true })
      return
    }
    emit('open-topic', props.msg)
  }

  /** The same menu as a right-click, opened from the button on the row. */
  function openMenuFromButton(ev: MouseEvent) {
    const btn = ev.currentTarget
    if (!(btn instanceof HTMLElement)) return
    pickerOpen.value = false
    if (menuOpen.value) {
      closeMenu()
      return
    }
    const r = btn.getBoundingClientRect()
    rowEl.value?.focus({ preventScroll: true })
    openMenuAt(r.left, r.bottom + 4)
  }

  function onMenuEdit() {
    closeMenu()
    startEdit()
  }

  /** A double-click on a row opens the same editor as `e`: a thread line on
      the right, and a level-1 card in the middle too. The browser has just
      selected the word under the pointer; that selection is cleared before
      the editor takes the caret. */
  function onDblClick(ev: MouseEvent) {
    const el = ev.target as HTMLElement | null
    const interactive = Boolean(el && el.closest && el.closest(INTERACTIVE))
    if (!wantsDblClickEdit(ev, {
      editable: Boolean(props.editable) && !editing.value,
      interactive,
    })) return
    ev.preventDefault()
    if (typeof window !== 'undefined') window.getSelection()?.removeAllRanges()
    startEdit()
  }
  return { onClick, openMenuFromButton, onMenuEdit, onDblClick }
}
