import { useIssueColumns } from '~/composables/useIssueColumns'
import { dragWidth, keyWidth, loadColWidths, saveColWidths, withColWidth } from '~/utils/issues-colw.mjs'

function headerWidth(grip: EventTarget | null): number {
  const th = grip instanceof HTMLElement ? grip.closest('th') : null
  return th ? th.getBoundingClientRect().width : 0
}

function isRtl(el: EventTarget | null): boolean {
  return el instanceof HTMLElement && getComputedStyle(el).direction === 'rtl'
}

/* Every cell of the column shrunk to its floor for one synchronous measure;
   each asks for its width plus whatever its content still overflows by (a
   clipped title, an ellipsised name). The styles are restored before paint. */
function measureFit(table: HTMLElement, col: string): number {
  let need = 0
  const cells = [...table.querySelectorAll<HTMLElement>(`[data-col="${col}"]`)]
  const saved = cells.map((el) => el.style.cssText)
  for (const el of cells) {
    el.style.width = '1%'
    el.style.minWidth = '0'
    el.style.maxWidth = 'none'
  }
  for (const el of cells) {
    let over = 0
    for (const d of [el, ...el.querySelectorAll<HTMLElement>('*')]) {
      /* only an element that clips (overflow not visible) hides content; an
         inline span reads clientWidth 0 and must not count */
      if (d.scrollWidth > d.clientWidth + 1 && getComputedStyle(d).overflowX !== 'visible') over = Math.max(over, d.scrollWidth - d.clientWidth)
    }
    need = Math.max(need, el.getBoundingClientRect().width + over)
  }
  for (const [i, el] of cells.entries()) el.style.cssText = saved[i]
  return need
}

/**
 * The issue sheet's resizable columns: drag a header's edge or use the arrow
 * keys on it; a double-click fits the column to its content. Moved out of
 * pages/issues.vue (CLE-77915, refactor item 10) unchanged.
 */
export function useIssueColumnGrips(opts: { table: () => HTMLElement | null | undefined }) {
  /* owner, topic beb4024f: resizable columns. A width set by dragging a
     header's edge (or the arrow keys on it) is the PERSON's (SPL-1132: the
     issues_columns claim kept on the hub, one PUT per gesture); signed out it
     is kept per browser. A column with no width keeps the automatic layout.
     colWidths is what the table draws: a drag writes it on every move, the
     store only on release. */
  const issueCols = useIssueColumns({ load: loadColWidths, save: saveColWidths })
  const colWidths = ref<Record<string, number>>({})
  let colDragging = false
  watch(issueCols.widths, (w) => { if (!colDragging) colWidths.value = { ...w } })
  function setColWidth(col: string, px: number) {
    colWidths.value = withColWidth(colWidths.value, col, px)
    issueCols.save(colWidths.value)
  }
  /* preventDefault on pointerdown (no text selection while dragging) also
     swallows the browser's dblclick, so a second press on the same grip
     within the double-click time is the double-click */
  let lastGripDown = { col: '', at: 0 }
  function onGripDown(ev: PointerEvent, col: string) {
    if (ev.button !== 0) return
    const grip = ev.currentTarget as HTMLElement
    ev.preventDefault()
    ev.stopPropagation()
    const now = ev.timeStamp || Date.now()
    if (lastGripDown.col === col && now - lastGripDown.at < 400) {
      lastGripDown = { col: '', at: 0 }
      void fitColumn(col)
      return
    }
    lastGripDown = { col, at: now }
    const startX = ev.clientX
    const startW = headerWidth(grip)
    const rtl = isRtl(grip)
    grip.setPointerCapture?.(ev.pointerId)
    grip.dataset.dragging = 'true'
    colDragging = true
    const move = (e: PointerEvent) => {
      const w = dragWidth(startW, e.clientX - startX, rtl, col)
      if (w != null) colWidths.value = withColWidth(colWidths.value, col, w)
    }
    const end = () => {
      grip.removeEventListener('pointermove', move)
      grip.removeEventListener('pointerup', end)
      grip.removeEventListener('pointercancel', end)
      delete grip.dataset.dragging
      colDragging = false
      issueCols.save(colWidths.value)
    }
    grip.addEventListener('pointermove', move)
    grip.addEventListener('pointerup', end)
    grip.addEventListener('pointercancel', end)
  }
  /* a double-click fits the column to its content (measureFit) */
  async function fitColumn(col: string) {
    colWidths.value = withColWidth(colWidths.value, col, 0)
    await nextTick()
    const table = opts.table()
    if (!table) return
    const need = measureFit(table, col)
    if (need > 0) setColWidth(col, Math.ceil(need))
  }
  function onGripKey(ev: KeyboardEvent, col: string) {
    const w = keyWidth(colWidths.value[col] || headerWidth(ev.currentTarget), ev.key, isRtl(ev.currentTarget), col)
    if (w == null) return
    ev.preventDefault()
    ev.stopPropagation()
    setColWidth(col, w)
  }

  return { issueCols, colWidths, onGripDown, onGripKey }
}
