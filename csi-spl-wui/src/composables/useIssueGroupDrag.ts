/**
 * Drag an issue row onto another status group = that status (the Status
 * cell does the same). Only the status view groups by status, so the drag
 * starts there only. Moved out of pages/issues.vue (CLE-77915, refactor item
 * 10); the page decides what a drop means.
 */
export function useIssueGroupDrag(opts: {
  enabled: () => boolean
  drop: (key: string, status: string) => void
}) {
  const dragKey = ref('')
  const dropStatus = ref('')

  function onRowDragStart(ev: DragEvent, issue: { key: string }) {
    if (!opts.enabled()) return
    dragKey.value = issue.key
    if (ev.dataTransfer) { ev.dataTransfer.effectAllowed = 'move'; ev.dataTransfer.setData('text/plain', issue.key) }
  }
  function onRowDragEnd() {
    dragKey.value = ''
    dropStatus.value = ''
  }
  function onGroupDragOver(ev: DragEvent, status: string) {
    if (!dragKey.value || !status) return
    ev.preventDefault()
    if (ev.dataTransfer) ev.dataTransfer.dropEffect = 'move'
    dropStatus.value = status
  }
  function onGroupDragLeave(ev: DragEvent, status: string) {
    const to = ev.relatedTarget
    if (dropStatus.value === status && !(to instanceof Node && (ev.currentTarget as HTMLElement).contains(to))) dropStatus.value = ''
  }
  function onGroupDrop(ev: DragEvent, status: string) {
    const key = dragKey.value || ev.dataTransfer?.getData('text/plain') || ''
    onRowDragEnd()
    if (!key || !status) return
    ev.preventDefault()
    opts.drop(key, status)
  }

  return { dropStatus, onRowDragStart, onRowDragEnd, onGroupDragOver, onGroupDragLeave, onGroupDrop }
}
