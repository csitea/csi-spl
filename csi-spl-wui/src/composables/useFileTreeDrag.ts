/*
 * r18-09: UiFileTree's SPL-1873 long-press menu and drag re-order, moved out
 * of UiFileTree.vue. A phone has no right-click: a held touch opens the
 * row's menu (touch-ui's timing); a drag row then lifts when the finger
 * moves (tree-drag.ts). A line marks the gap the row lands in; Escape
 * cancels.
 *
 * The rows and the caller's canDrop are getters so a changed prop is read
 * on the next call. The view keeps its roving focus and keyboard; its
 * onBeforeUnmount calls dispose.
 */
import { ref, type Ref } from 'vue'
import type { FileTreeDrop, FileTreeRow } from '~/components/UiFileTree.vue'
import { createTreeDrag, dropWhere } from '~/utils/tree-drag'

type TreeDragEmit = {
  (e: 'move', key: string, target: string, where: FileTreeDrop): void
  (e: 'lift', key: string): void
}

type FileTreeDragOpts = {
  rows: () => FileTreeRow[]
  canDrop: () => ((key: string, target: string, where: FileTreeDrop) => boolean) | undefined
  els: Map<string, HTMLElement>
  focusKey: Ref<string>
  openMenu: (i: number, x: number, y: number) => void
  select: (i: number) => void
  emit: TreeDragEmit
}

export function useFileTreeDrag(o: FileTreeDragOpts) {
  let pressAt = -1
  let pressPointer = -1
  const dragKey = ref('')
  const dropAt = ref<{ key: string, where: FileTreeDrop } | null>(null)

  function canDrop(target: string, where: FileTreeDrop): boolean {
    const t = o.rows().find((r) => r.key === target)
    if (!t || target === dragKey.value || (where === 'into' && !t.into)) return false
    const rule = o.canDrop()
    return rule ? rule(dragKey.value, target, where) : where !== 'into'
  }

  /** the row under the pointer and the place on it */
  function track(x: number, y: number) {
    const el = document.elementFromPoint(x, y)?.closest('[data-test=file-tree-row]')
    const key = el instanceof HTMLElement ? el.dataset.key || '' : ''
    if (!key || !el || o.els.get(key) !== el) {
      dropAt.value = null
      return
    }
    const where = dropWhere(y, el.getBoundingClientRect(), { before: canDrop(key, 'before'), after: canDrop(key, 'after'), into: canDrop(key, 'into') })
    dropAt.value = where ? { key, where } : null
  }

  function endDrag() {
    dragKey.value = ''
    dropAt.value = null
    window.removeEventListener('keydown', onEscape, true)
  }

  function onEscape(e: KeyboardEvent) {
    if (e.key !== 'Escape') return
    e.preventDefault()
    e.stopPropagation()
    gesture.cancel()
  }

  const gesture = createTreeDrag({
    onHold: (x, y) => o.openMenu(pressAt, x, y),
    onStart: () => {
      const row = o.rows()[pressAt]
      if (!row) return
      dragKey.value = row.key
      o.focusKey.value = row.key
      try { o.els.get(row.key)?.setPointerCapture(pressPointer) } catch { /* the pointer is gone */ }
      window.addEventListener('keydown', onEscape, true)
      o.emit('lift', row.key)
    },
    onMove: track,
    onDrop: (x, y) => {
      track(x, y)
      const key = dragKey.value
      const at = dropAt.value
      endDrag()
      if (key && at) o.emit('move', key, at.key, at.where)
    },
    onCancel: endDrag,
  })
  function press(i: number, e: PointerEvent) {
    pressAt = i
    pressPointer = e.pointerId
    gesture.down(e, Boolean(o.rows()[i]?.drag))
  }
  /* a held finger drags: the list under it does not scroll */
  function onTouchMove(e: TouchEvent) {
    if (gesture.holding && e.cancelable) e.preventDefault()
  }
  /* the click a finger sends as it lifts from a long press, or a drag's release, does not also select */
  function onRowClick(i: number) {
    if (gesture.takeClick()) return
    o.select(i)
  }
  function dispose() {
    gesture.cancel()
    endDrag()
  }

  return { dragKey, dropAt, gesture, press, onTouchMove, onRowClick, dispose }
}
