// csi-spl-wui/src/utils/dialog-drag.mjs
//
// Spec 182 v0.11 change 4 (HUM-10, t1 6e8c1cdb msg e68509d5, SPL-6583): "the
// dialog box should be draggable back and forth on the screen". The pure
// half of UiDialog's `draggable` (composables/useDialogDrag.ts): where a
// drag may put the panel. Pure: the Node tests import it.

/**
 * The panel's offset after a drag, clamped so the whole panel stays on
 * screen; a panel larger than the viewport keeps its top left corner on it.
 *
 * @param {{ x: number, y: number }} want the offset the pointer asks for
 * @param {{ left: number, top: number, width: number, height: number }} base the panel's rect at offset 0
 * @param {{ width: number, height: number }} view the viewport
 * @returns {{ x: number, y: number }}
 */
export function dialogDragOffset(want, base, view) {
  const axis = (d, start, size, room) => {
    const lo = -start
    const hi = Math.max(lo, room - size - start)
    return Math.min(hi, Math.max(lo, Number(d) || 0))
  }
  return { x: axis(want.x, base.left, base.width, view.width), y: axis(want.y, base.top, base.height, view.height) }
}
