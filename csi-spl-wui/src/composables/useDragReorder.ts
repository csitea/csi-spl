// SPL-979: pointer (mouse, pen, touch) drag to reorder a vertical list, shared
// by the left rail and the Settings list. A press only becomes a drag past
// DRAG_THRESHOLD_PX, so a plain click still clicks; the click that ends a drag
// is swallowed. While dragging, `preview` is the order to draw.
// CLE-77916: a list laid out in a row (the phone strip) is measured along x
// (dragAxis); `normalize` keeps a pinned item where it belongs in the preview.
import { DRAG_THRESHOLD_PX, dragAxis, dropIndex, isDrag, moveTo, sameOrder } from '~/utils/rail-order.mjs'

export function useDragReorder<T extends string>(opts: {
  order: () => readonly T[]
  /** the item elements, in the current order, each with data-reorder-id */
  items: () => HTMLElement[]
  onDrop: (next: T[]) => void
  /** the order as it may be drawn and saved (e.g. a pinned item put back) */
  normalize?: (order: T[]) => T[]
}) {
  const norm = (o: T[]) => (opts.normalize ? opts.normalize(o) : o)
  const preview = ref<T[] | null>(null) as Ref<T[] | null>
  const draggingId = ref<T | ''>('') as Ref<T | ''>
  let start: { x: number, y: number, id: T, pointerId: number, el: HTMLElement } | null = null
  let mids: number[] = []
  let base: T[] = []
  let along = (ev: PointerEvent) => ev.clientY

  function swallowClick() {
    const stop = (e: Event) => { e.preventDefault(); e.stopPropagation() }
    window.addEventListener('click', stop, { capture: true, once: true })
    setTimeout(() => window.removeEventListener('click', stop, { capture: true }), 400)
  }

  function onMove(ev: PointerEvent) {
    if (!start || ev.pointerId !== start.pointerId) return
    if (!draggingId.value) {
      if (!isDrag(ev.clientX - start.x, ev.clientY - start.y, DRAG_THRESHOLD_PX)) return
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

  function finish(ev: PointerEvent, drop: boolean) {
    if (!start || ev.pointerId !== start.pointerId) return
    const next = preview.value
    const dragged = Boolean(draggingId.value)
    start = null
    preview.value = null
    draggingId.value = ''
    window.removeEventListener('pointermove', onMove)
    window.removeEventListener('pointerup', onUp)
    window.removeEventListener('pointercancel', onCancel)
    if (!dragged) return
    swallowClick()
    if (drop && next && !sameOrder(next, base)) opts.onDrop(next)
  }
  function onUp(ev: PointerEvent) { finish(ev, true) }
  function onCancel(ev: PointerEvent) { finish(ev, false) }

  /** pointerdown on an item: arms a drag; nothing happens until the pointer moves far enough. */
  function down(ev: PointerEvent, id: T) {
    if (ev.button !== 0 || start) return
    start = { x: ev.clientX, y: ev.clientY, id, pointerId: ev.pointerId, el: ev.currentTarget as HTMLElement }
    window.addEventListener('pointermove', onMove, { passive: false })
    window.addEventListener('pointerup', onUp)
    window.addEventListener('pointercancel', onCancel)
  }

  onBeforeUnmount(() => {
    window.removeEventListener('pointermove', onMove)
    window.removeEventListener('pointerup', onUp)
    window.removeEventListener('pointercancel', onCancel)
  })

  return { preview, draggingId, down }
}
