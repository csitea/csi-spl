// SPL-979: pointer (mouse, pen, touch) drag to reorder a vertical list, shared
// by the left rail and the Settings list. A press only becomes a drag past
// DRAG_THRESHOLD_PX, so a plain click still clicks; the click that ends a drag
// is swallowed. While dragging, `preview` is the order to draw.
// CLE-77916: a list laid out in a row (the phone strip) is measured along x
// (dragAxis); `normalize` keeps a pinned item where it belongs in the preview.
// Owner (t1 topic 7b48293b, HUM-10): a finger swipe on the phone strip
// "doesn't scroll smoothly, they reset" - 6 px in, the swipe became a drag:
// the pointer was captured, the tabs reshuffled, and the browser's pan then
// cancelled it back. `touchHoldMs`: on touch a drag needs a press held that
// long without moving; a move before then is the browser's scroll.
import { DRAG_THRESHOLD_PX, dragAxis, dropIndex, isDrag, moveTo, sameOrder } from '~/utils/rail-order.mjs'

/* how long after a drag ends its click may still land and be swallowed; a
 * click later than this is the reader's own. Unrelated to the 400 ms in
 * useIssueColumnGrips. */
const SWALLOW_CLICK_MS = 400

function swallowClick() {
  const stop = (e: Event) => { e.preventDefault(); e.stopPropagation() }
  window.addEventListener('click', stop, { capture: true, once: true })
  setTimeout(() => window.removeEventListener('click', stop, { capture: true }), SWALLOW_CLICK_MS)
}

export function useDragReorder<T extends string>(opts: {
  order: () => readonly T[]
  /** the item elements, in the current order, each with data-reorder-id */
  items: () => HTMLElement[]
  onDrop: (next: T[]) => void
  /** the order as it may be drawn and saved (e.g. a pinned item put back) */
  normalize?: (order: T[]) => T[]
  /** touch only: the hold before a press may drag (0: a drag at once, as a grip) */
  touchHoldMs?: number
}) {
  const norm = (o: T[]) => (opts.normalize ? opts.normalize(o) : o)
  const preview = ref<T[] | null>(null) as Ref<T[] | null>
  const draggingId = ref<T | ''>('') as Ref<T | ''>
  let start: { x: number, y: number, id: T, pointerId: number, el: HTMLElement, held: boolean } | null = null
  let hold: ReturnType<typeof setTimeout> | undefined
  let mids: number[] = []
  let base: T[] = []
  let along = (ev: PointerEvent) => ev.clientY
  /* one per press: abort() removes all down() added; finish() aborts it before `start` frees down() again */
  let listeners: AbortController | null = null

  function onMove(ev: PointerEvent) {
    if (!start || ev.pointerId !== start.pointerId) return
    if (!draggingId.value) {
      if (!isDrag(ev.clientX - start.x, ev.clientY - start.y, DRAG_THRESHOLD_PX)) return
      /* moved before the hold ran out: a scroll, not a drag */
      if (!start.held) { finish(ev, false); return }
      base = [...opts.order()]
      const rects = opts.items().map((el) => el.getBoundingClientRect())
      const { axis, sign } = dragAxis(rects)
      along = axis === 'x' ? (e) => sign * e.clientX : (e) => e.clientY
      mids = rects.map((r) => (axis === 'x' ? sign * (r.left + r.width / 2) : r.top + r.height / 2))
      draggingId.value = start.id
      try { start.el.setPointerCapture(ev.pointerId) } catch { /* released already */ }
    }
    ev.preventDefault()
    const from = base.indexOf(start.id)
    preview.value = norm(moveTo(base, start.id, dropIndex(mids, from, along(ev))))
  }

  /* once held, the finger drags the item: the browser must not pan under it */
  const onTouchMove = (ev: TouchEvent) => { if (start?.held && ev.cancelable) ev.preventDefault() }

  function unlisten() {
    clearTimeout(hold)
    listeners?.abort()
  }

  function finish(ev: PointerEvent, drop: boolean) {
    if (!start || ev.pointerId !== start.pointerId) return
    const next = preview.value
    const dragged = Boolean(draggingId.value)
    start = null
    preview.value = null
    draggingId.value = ''
    unlisten()
    if (!dragged) return
    swallowClick()
    if (drop && next && !sameOrder(next, base)) opts.onDrop(next)
  }
  function onUp(ev: PointerEvent) { finish(ev, true) }
  function onCancel(ev: PointerEvent) { finish(ev, false) }

  /** pointerdown on an item: arms a drag; nothing happens until the pointer moves far enough. */
  function down(ev: PointerEvent, id: T) {
    if (ev.button !== 0 || start) return
    const wait = ev.pointerType === 'touch' ? opts.touchHoldMs || 0 : 0
    const s = { x: ev.clientX, y: ev.clientY, id, pointerId: ev.pointerId, el: ev.currentTarget as HTMLElement, held: wait <= 0 }
    start = s
    if (!s.held) hold = setTimeout(() => { s.held = true }, wait)
    const { signal } = (listeners = new AbortController())
    window.addEventListener('pointermove', onMove, { passive: false, signal })
    window.addEventListener('pointerup', onUp, { signal })
    window.addEventListener('pointercancel', onCancel, { signal })
    if (wait > 0) window.addEventListener('touchmove', onTouchMove, { passive: false, signal })
  }
  onBeforeUnmount(unlisten)

  return { preview, draggingId, down }
}
