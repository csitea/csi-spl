import type { ComputedRef, Ref } from 'vue'
import type { Issue } from '~/utils/issues.mjs'
import { localInputToDeadline } from '~/utils/issues-view.mjs'
import type { IssuePickerMenu, IssueSave } from '~/composables/issuesPageTypes'

/**
 * SPL-1027: the sheet's cell cursor (the row is cursorKey), the title being
 * edited in place and the row whose deadline picker is open. Moved out of
 * pages/issues.vue (r13-06).
 */
export type IssueCellsOpts = {
  pageEl: Ref<HTMLElement | null>
  cursorKey: Ref<string>
  flat: ComputedRef<Issue[]>
  menu: Ref<IssuePickerMenu | null>
  save: IssueSave
  openMenu: (kind: string, issue: Issue, ev?: Event) => void
  askDelete: (issue: Issue) => void
  choose: (issue: Issue) => void
}

const SHEET_COLS = ['key', 'title', 'status', 'priority', 'level', 'assignee', 'label', 'deadline', 'updated', 'actions'] as const

export function useIssueCells(o: IssueCellsOpts) {
  const cursorCol = ref('')
  function cellAttrs(issue: Issue, col: string) {
    return {
      'data-col': col,
      'data-cell-on': o.cursorKey.value === issue.key && cursorCol.value === col ? 'true' : undefined,
      tabindex: -1,
    }
  }
  function cellEl(key: string, col: string): HTMLElement | null {
    return o.pageEl.value?.querySelector(`[data-test=issues-row][data-key="${CSS.escape(key)}"] [data-col="${col}"]`) || null
  }
  function focusCell() {
    void nextTick(() => {
      if (!o.cursorKey.value || !cursorCol.value) return
      cellEl(o.cursorKey.value, cursorCol.value)?.focus()
    })
  }
  function stepCol(delta: number) {
    if (!o.cursorKey.value) o.cursorKey.value = o.flat.value[0]?.key || ''
    if (!o.cursorKey.value) return
    const at = SHEET_COLS.indexOf(cursorCol.value as typeof SHEET_COLS[number])
    const from = at < 0 ? (delta > 0 ? 0 : 1) : at
    cursorCol.value = SHEET_COLS[Math.max(0, Math.min(SHEET_COLS.length - 1, from + (at < 0 ? 0 : delta)))]
    focusCell()
  }
  const edits = useCellEdits(o, cursorCol, focusCell)
  /* Enter on a cell: the key and Updated open the issue, every other cell edits */
  function editCell(issue: Issue, col: string) {
    const td = cellEl(issue.key, col)
    const at = td ? { currentTarget: td } as unknown as Event : undefined
    if (col === 'title') { edits.startTitleEdit(issue); return }
    if (col === 'status') { o.openMenu('status', issue, at); return }
    if (col === 'assignee') { o.openMenu('assign', issue, at); return }
    if (col === 'label') { o.openMenu('label', issue, at); return }
    if (col === 'deadline') { edits.startDeadlineEdit(issue); return }
    if (col === 'actions') { o.askDelete(issue); return }
    if (col === 'priority' || col === 'level') {
      const sel = td?.querySelector('select') as (HTMLSelectElement & { showPicker?: () => void }) | null
      sel?.focus()
      try { sel?.showPicker?.() } catch { /* focus is enough: the arrows pick */ }
      return
    }
    o.choose(issue)
  }
  return { cursorCol, cellAttrs, cellEl, focusCell, stepCol, editCell, ...edits }
}

function useCellEdits(o: IssueCellsOpts, cursorCol: Ref<string>, focusCell: () => void) {
  const titleEdit = reactive({ key: '', text: '' })
  const deadlineEditKey = ref('')
  function startTitleEdit(issue: Issue) {
    o.cursorKey.value = issue.key
    cursorCol.value = 'title'
    o.menu.value = null
    titleEdit.key = issue.key
    titleEdit.text = issue.title
    void nextTick(() => {
      const el = o.pageEl.value?.querySelector<HTMLInputElement>('[data-test=issues-row-title-input]')
      el?.focus()
      el?.select()
    })
  }
  function commitRowTitle(issue: Issue) {
    if (titleEdit.key !== issue.key) return
    const value = titleEdit.text.trim()
    titleEdit.key = ''
    if (value && value !== issue.title) void o.save(issue.key, { title: value })
  }
  function onRowTitleKey(ev: KeyboardEvent, issue: Issue) {
    if (ev.key === 'Enter') { ev.preventDefault(); commitRowTitle(issue); focusCell(); return }
    if (ev.key === 'Escape') { ev.preventDefault(); titleEdit.key = ''; focusCell() }
  }
  function startDeadlineEdit(issue: Issue) {
    o.cursorKey.value = issue.key
    cursorCol.value = 'deadline'
    o.menu.value = null
    deadlineEditKey.value = issue.key
    void nextTick(() => o.pageEl.value?.querySelector<HTMLInputElement>('[data-test=issues-row-deadline-input]')?.focus())
  }
  function onRowDeadline(issue: Issue, local: string) {
    deadlineEditKey.value = ''
    const deadline = localInputToDeadline(local)
    if (deadline === null || deadline === (issue.deadline || '')) { focusCell(); return }
    void o.save(issue.key, { deadline })
    focusCell()
  }
  return { titleEdit, deadlineEditKey, startTitleEdit, commitRowTitle, onRowTitleKey, startDeadlineEdit, onRowDeadline }
}
