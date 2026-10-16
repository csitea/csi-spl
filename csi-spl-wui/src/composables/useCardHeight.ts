/*
 * the card's height in the middle pane (MessageCard, split out in r13-01;
 * utils/card-clip.mjs holds the rule and its tests). The box is measured, not
 * guessed: the line height is read from the rendered body, so the 5 rows
 * follow the font-size setting (rem), and "clipped" is the content being
 * taller than the box, so a short card never shows a grip. Editing lifts the
 * clip: the textarea sizes itself.
 */
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch, type Ref } from 'vue'
import {
  CARD_GRIP_STEP_ROWS,
  cardClipPx,
  cardClipStyle,
  cardDragPx,
  cardIsClipped,
  cardTitle,
} from '~/utils/card-clip.mjs'
import { onViewportResize } from '~/utils/viewport-resize.mjs'
import type { CardClipMode } from '~/composables/useCardClip'
import { useLinkPreviewRefs } from '~/composables/useLinkPreviewRefs'
import type { FileRef, SpoolMessage } from '~/types/spool'

type ClipProps = { msg: SpoolMessage, clipMode?: CardClipMode }

/** The card's one-line title, and the link cards its body carries. */
export function useCardTitle(props: ClipProps, editing: Ref<boolean>, files: Ref<FileRef[]>) {
  const titleOnly = computed(() => props.clipMode === 'titles' && !editing.value)
  /* topic e1f8f797: the body's internal links, as preview cards inside the clip (t1 c7ddbf83) */
  const linkPreviews = useLinkPreviewRefs(() => String(props.msg.body || ''), {
    skip: () => [String(props.msg.msg_id || ''), String(props.msg.task_id || ''), String(props.msg.parent_task_id || '')],
  })
  const title = computed(() => {
    const own = cardTitle(String(props.msg.body || ''))
    if (own) return own
    return cardTitle(files.value.map((f) => String(f.name || '')).filter(Boolean).join(', '))
  })
  return { titleOnly, linkPreviews, title }
}

/** What measure() reads off the rendered card, px. */
interface Measured { lineHeightPx: Ref<number>, contentPx: Ref<number>, notesPx: Ref<number> }

/* SPL-2104: the note lines right over the clip box ("moved from", the DM's
   topic, a pointer), top of the first to top of the box, px */
function notesOver(box: HTMLElement | null): number {
  if (!box) return 0
  let first: Element | null = null
  for (let el = box.previousElementSibling; el?.classList.contains('msg-moved'); el = el.previousElementSibling) first = el
  return first ? Math.max(0, box.getBoundingClientRect().top - first.getBoundingClientRect().top) : 0
}

function measureBox(clipInner: Ref<HTMLElement | null>, m: Measured) {
  if (typeof window === 'undefined') return
  const inner = clipInner.value
  if (!inner) return
  const body = inner.querySelector<HTMLElement>('.msg-body') || inner
  const style = getComputedStyle(body)
  const lh = parseFloat(style.lineHeight)
  const fs = parseFloat(style.fontSize) || 14
  m.lineHeightPx.value = Number.isFinite(lh) && lh > 0 ? lh : fs * 1.45
  m.contentPx.value = Math.ceil(inner.scrollHeight)
  m.notesPx.value = Math.round(notesOver(inner.parentElement))
}

export function useCardHeight(props: ClipProps, editing: Ref<boolean>, clipEl: Ref<HTMLElement | null>, clipInner: Ref<HTMLElement | null>) {
  /* SPL-1871 (owner t1 c3396e3c): a card holding a ```poll form takes the
     reader's 5 rows like any card, "the same as with the links previews": the
     options under the cut fade out and the grip shows them all (SPL-1637 had
     left the form unclipped, so it drew at full height past the limit) */
  const clipOn = computed(() => props.clipMode === 'rows' && !editing.value)
  /** A grip drag on this card, px; null = the automatic height. Never stored. */
  const userPx = ref<number | null>(null)
  const m: Measured = { lineHeightPx: ref(0), contentPx: ref(0), notesPx: ref(0) }
  const { lineHeightPx, contentPx, notesPx } = m
  const clipPx = computed(() => {
    if (!clipOn.value || !lineHeightPx.value) return null
    return cardClipPx({
      mode: 'rows',
      lineHeightPx: lineHeightPx.value,
      userPx: userPx.value,
      notesPx: notesPx.value,
    })
  })
  const clipped = computed(() => clipPx.value != null && cardIsClipped(contentPx.value, clipPx.value))
  /* Before the first measurement the stylesheet's own 5-row box holds.
     SPL-2087: min = max, so a 1-row card is as tall as a cut one. */
  const clipStyle = computed(() => cardClipStyle(clipPx.value))
  const measure = () => measureBox(clipInner, m)

  let clipObserver: ResizeObserver | null = null
  let offResize: (() => void) | null = null
  function stopObserving() {
    clipObserver?.disconnect()
    clipObserver = null
    offResize?.()
    offResize = null
  }
  function startObserving() {
    stopObserving()
    if (typeof window === 'undefined' || !clipOn.value || !clipInner.value) return
    measure()
    if (typeof ResizeObserver !== 'undefined') {
      clipObserver = new ResizeObserver(() => measure())
      clipObserver.observe(clipInner.value)
    }
    /* one shared window listener, once per frame (CLE-35075) */
    offResize = onViewportResize(measure)
  }
  watch([clipOn, clipInner], () => { void nextTick(startObserving) })
  onMounted(() => startObserving())
  onBeforeUnmount(stopObserving)
  /* Another mode, or another message under this card: back to the automatic height.
     Two sources, each compared by value: one getter returning [mode, id] is a
     new array on every run, so a fresh list of the same rows (a live message,
     a refetch) closed a card the reader had just opened. */
  watch([() => props.clipMode, () => String(props.msg?.msg_id || '')], () => { userPx.value = null })

  return { clipOn, userPx, clipped, clipStyle, ...useCardGrip(clipEl, clipPx, clipped, userPx, m, measure) }
}

/** The grip under a clipped card: drag it, click it, or step it by keys. */
function useCardGrip(clipEl: Ref<HTMLElement | null>, clipPx: Ref<number | null>, clipped: Ref<boolean>, userPx: Ref<number | null>, m: Measured, measure: () => void) {
  const { lineHeightPx, contentPx } = m
  let gripDragged = false
  function startGrip(ev: PointerEvent) {
    const box = clipEl.value
    const handle = ev.currentTarget
    if (!box || !(handle instanceof HTMLElement)) return
    ev.preventDefault()
    measure()
    handle.setPointerCapture(ev.pointerId)
    gripDragged = false
    const startY = ev.clientY
    const startH = box.getBoundingClientRect().height
    const move = (e: PointerEvent) => {
      const dy = e.clientY - startY
      if (!gripDragged && Math.abs(dy) < 3) return
      gripDragged = true
      userPx.value = cardDragPx(startH, dy, lineHeightPx.value, contentPx.value)
    }
    const end = () => {
      handle.removeEventListener('pointermove', move)
      handle.removeEventListener('pointerup', end)
      handle.removeEventListener('pointercancel', end)
    }
    handle.addEventListener('pointermove', move)
    handle.addEventListener('pointerup', end)
    handle.addEventListener('pointercancel', end)
  }

  /** A click (or Enter / Space) on the grip: all of it, or back to the automatic height. */
  function onGripClick() {
    if (gripDragged) {
      gripDragged = false
      return
    }
    measure()
    userPx.value = clipped.value ? contentPx.value : null
  }

  /** Arrow Down / Up: two rows more or less, from one row to the whole card. */
  function onGripKey(ev: KeyboardEvent) {
    if (ev.key !== 'ArrowDown' && ev.key !== 'ArrowUp') return
    ev.preventDefault()
    ev.stopPropagation()
    measure()
    const now = clipEl.value?.getBoundingClientRect().height || clipPx.value || 0
    const step = lineHeightPx.value * CARD_GRIP_STEP_ROWS * (ev.key === 'ArrowDown' ? 1 : -1)
    userPx.value = cardDragPx(now, step, lineHeightPx.value, contentPx.value)
  }
  return { startGrip, onGripClick, onGripKey }
}
