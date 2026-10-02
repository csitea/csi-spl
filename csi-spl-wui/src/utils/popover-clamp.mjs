/**
 * SPL-1147: where a pop-up anchored under a field goes, always fully inside
 * the viewport. Under the field, left edges aligned; near the right edge it
 * opens to the left (right edges aligned), near the bottom it opens upwards
 * (when that fits); then it is clamped `edge` px inside. Pure: the caller
 * does the DOM reads (components/DeadlinePicker.vue place()).
 *
 * @param {{
 *   anchor: { left: number, right: number, top: number, bottom: number },
 *   w: number, h: number, vw: number, vh: number,
 *   edge?: number, gap?: number,
 * }} o
 * @returns {{ left: number, top: number }}
 */
export function clampPopover({ anchor, w, h, vw, vh, edge = 8, gap = 4 }) {
  let left = anchor.left
  if (left + w > vw - edge) left = anchor.right - w
  left = Math.max(edge, Math.min(left, vw - w - edge))
  let top = anchor.bottom + gap
  if (top + h > vh - edge && anchor.top - gap - h >= edge) top = anchor.top - gap - h
  top = Math.max(edge, Math.min(top, vh - h - edge))
  return { left, top }
}
