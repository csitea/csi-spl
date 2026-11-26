/*
 * Spec 182 v0.11 change 4 (HUM-10, t1 6e8c1cdb msg e68509d5, SPL-6583): a
 * UiDialog with `draggable` moves by its header, with a mouse, a pen or a
 * finger (pointer events), and stays on screen (utils/dialog-drag.mjs).
 * A press on a header button (Close, a tool) is that button's, not a drag.
 * Desktop only (owner msg 5c03fa45): at <= 600 px the dialog is a full
 * screen and does not move. Each open starts where the CSS puts it.
 */
import { ref, type Ref } from 'vue'
import { dialogDragOffset } from '~/utils/dialog-drag.mjs'

const PHONE = '(max-width: 600px)'
const NOT_A_HANDLE = 'button, a, input, select, textarea, [role="button"]'

export function useDialogDrag(panel: Ref<HTMLElement | null>, enabled: () => boolean) {
  const offset = ref({ x: 0, y: 0 })
  let start: { px: number, py: number, x: number, y: number, base: DOMRect } | null = null

  function base(): DOMRect | null {
    const el = panel.value
    if (!el) return null
    const r = el.getBoundingClientRect()
    return new DOMRect(r.left - offset.value.x, r.top - offset.value.y, r.width, r.height)
  }

  function onDown(ev: PointerEvent) {
    if (!enabled() || ev.button !== 0 || window.matchMedia(PHONE).matches) return
    if ((ev.target as Element | null)?.closest(NOT_A_HANDLE)) return
    const b = base()
    if (!b) return
    start = { px: ev.clientX, py: ev.clientY, x: offset.value.x, y: offset.value.y, base: b }
    ;(ev.currentTarget as Element).setPointerCapture?.(ev.pointerId)
    ev.preventDefault()
  }

  function onMove(ev: PointerEvent) {
    if (!start) return
    const want = { x: start.x + ev.clientX - start.px, y: start.y + ev.clientY - start.py }
    offset.value = dialogDragOffset(want, start.base, { width: window.innerWidth, height: window.innerHeight })
  }

  function onUp(ev: PointerEvent) {
    if (!start) return
    start = null
    ;(ev.currentTarget as Element).releasePointerCapture?.(ev.pointerId)
  }

  /* a smaller window pulls a moved dialog back on screen */
  function onResize() {
    const b = base()
    if (b && (offset.value.x || offset.value.y)) offset.value = dialogDragOffset(offset.value, b, { width: window.innerWidth, height: window.innerHeight })
  }

  function reset() {
    start = null
    offset.value = { x: 0, y: 0 }
  }

  return { offset, onDown, onMove, onUp, onResize, reset }
}
