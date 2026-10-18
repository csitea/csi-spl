import type { ComputedRef, Ref, WatchSource } from 'vue'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { isTopKind, type Issue } from '~/utils/issues.mjs'
import { keepShown, pageState, rangeSelect, runBulk, toggleAll, toggleKey } from '~/utils/issues-bulk.mjs'
import type { BulkAction } from '~/components/IssuesBulkBar.vue'
import type { IssuePickerMenu, IssuesApi } from '~/composables/issuesPageTypes'

/**
 * Owner HUM-10 (t1 53ab04e7, msg 14b0e604): Gmail-style checkboxes. "the
 * issues listing should have checkboxes to perform multiple actions the same
 * way as in gmail". A box per row and a page box; shift-click checks a run,
 * x the focused row, Esc clears. With one row checked the bulk bar
 * (components/IssuesBulkBar.vue, lazy) replaces the header. The hub has no
 * bulk route; per-issue calls, BULK_PARALLEL at a time, were measured fast
 * enough on dev (2026-10-12, n=6 status PATCHes, ~0.3..0.6 s each). Moved
 * out of pages/issues.vue (r13-06).
 */
export type IssueBulkOpts = {
  api: IssuesApi
  issues: Ref<Issue[]>
  flat: ComputedRef<Issue[]>
  nextCursor: Ref<string>
  matchTotal: Ref<number>
  loadError: Ref<string>
  cursorKey: Ref<string>
  menu: Ref<IssuePickerMenu | null>
  menuPos: Ref<{ top: number, left: number }>
  menuIndex: Ref<number>
  pageBoxEl: Ref<HTMLInputElement | null>
  /* another filter is another list: nothing stays checked (Gmail) */
  filters: WatchSource[]
  loadMore: () => Promise<void>
  clampMenuIntoView: () => void
  dropKeys: (keys: string[]) => void
  keepOrDrop: (key: string, data: { issue: Issue }) => void
  refreshEpics: () => void
}

function bulkState(o: IssueBulkOpts) {
  const selected = ref<string[]>([])
  const flatKeys = computed(() => o.flat.value.map((i) => i.key))
  const bulkPage = computed(() => pageState(selected.value, flatKeys.value))
  return {
    selected,
    selSet: computed(() => new Set(selected.value)),
    bulkOn: computed(() => selected.value.length > 0),
    flatKeys,
    bulkPage,
    allMatching: ref(false),
    selectingAll: ref(false),
    canMatchAll: computed(() => bulkPage.value === 'all' && (Boolean(o.nextCursor.value) || o.matchTotal.value > flatKeys.value.length)),
    bulkBusy: ref(false),
    bulkProgress: ref<{ done: number, total: number } | null>(null),
    bulkResult: ref<{ done: number, total: number, failed: string[] } | null>(null),
    bulkConfirm: ref<'archive' | 'delete' | ''>(''),
  }
}
type BulkState = ReturnType<typeof bulkState>

export function useIssueBulk(o: IssueBulkOpts) {
  const s = bulkState(o)
  const pick = useBulkPick(o, s)
  /* the page box's dash: some rows shown are checked */
  watchEffect(() => { if (o.pageBoxEl.value) o.pageBoxEl.value.indeterminate = s.bulkPage.value === 'some' })
  watch(o.filters, () => pick.clearSelection())
  /* a row that left the list (deleted, archived, live) leaves the selection */
  watch(o.issues, (rows) => {
    const next = keepShown(s.selected.value, rows.map((i) => i.key))
    if (next !== s.selected.value) s.selected.value = next
  })
  return { ...s, ...pick, ...useBulkRun(o, s) }
}

function useBulkPick(o: IssueBulkOpts, s: BulkState) {
  let checkAnchor = ''
  function setSelected(next: string[]) {
    if (next === s.selected.value) return
    s.selected.value = next
    s.allMatching.value = false
    s.bulkResult.value = null
  }
  function clearSelection() {
    setSelected([])
    checkAnchor = ''
  }
  function onCheck(issue: Issue, ev: MouseEvent) {
    const on = !s.selSet.value.has(issue.key)
    setSelected(ev.shiftKey && checkAnchor
      ? rangeSelect(s.selected.value, s.flatKeys.value, checkAnchor, issue.key, on)
      : toggleKey(s.selected.value, issue.key, on))
    checkAnchor = issue.key
    o.cursorKey.value = issue.key
    /* the box takes no focus: the row keeps it, so j / k / x go on */
    const row = (ev.target as HTMLElement | null)?.closest?.<HTMLElement>('[data-test=issues-row]')
    row?.focus({ preventScroll: true })
  }
  function togglePage() {
    setSelected(toggleAll(s.selected.value, s.flatKeys.value))
  }
  function toggleFocused() {
    const focused = (document.activeElement as HTMLElement | null)?.closest?.<HTMLElement>('[data-test=issues-row], [data-test=issues-card]')
    const key = focused?.getAttribute('data-key') || o.cursorKey.value
    if (!key || !s.flatKeys.value.includes(key)) return
    setSelected(toggleKey(s.selected.value, key))
    checkAnchor = key
    o.cursorKey.value = key
  }
  /* Gmail's "Select all N matching": read the pages not loaded yet, then check them all */
  async function selectAllMatching() {
    if (s.selectingAll.value) return
    s.selectingAll.value = true
    try {
      for (let i = 0; i < 100 && o.nextCursor.value && !o.loadError.value; i++) await o.loadMore()
      setSelected(toggleAll([], s.flatKeys.value))
      s.allMatching.value = !o.nextCursor.value
    } finally {
      s.selectingAll.value = false
    }
  }
  return { clearSelection, onCheck, togglePage, toggleFocused, selectAllMatching }
}

function useBulkRun(o: IssueBulkOpts, s: BulkState) {
  /* one progress line while it runs, one summary naming the rows that failed;
     those stay checked, the rows done leave the selection */
  async function runBulkCalls(fn: (key: string) => Promise<void>) {
    const keys = [...s.selected.value]
    s.bulkBusy.value = true
    s.bulkResult.value = null
    s.bulkProgress.value = { done: 0, total: keys.length }
    try {
      const out = await runBulk(keys, fn, { onProgress: (done, total) => { s.bulkProgress.value = { done, total } } })
      const failed = out.failed.map((f) => f.key)
      /* a changed row stays checked (Gmail), an archived / deleted one is gone */
      s.selected.value = keepShown(keys, o.issues.value.map((i) => i.key))
      s.allMatching.value = false
      s.bulkResult.value = { done: out.done.length, total: keys.length, failed }
      o.refreshEpics()
    } finally {
      s.bulkProgress.value = null
      s.bulkBusy.value = false
    }
  }
  function onBulkAct(id: BulkAction, ev: MouseEvent) {
    if (s.bulkBusy.value || !s.selected.value.length) return
    if (id === 'archive' || id === 'delete') { s.bulkConfirm.value = id; return }
    /* the row menu's pickers (applyMenu), aimed at every checked row */
    const kind = id === 'move' ? 'move-epic' : id
    const el = ev.currentTarget as HTMLElement | null
    const r = el?.getBoundingClientRect?.()
    o.menuPos.value = { top: r ? r.bottom + 4 : 120, left: Math.max(8, r ? r.left : 80) }
    o.menu.value = { kind, key: '', bulk: true }
    o.menuIndex.value = 0
    void nextTick(o.clampMenuIntoView)
  }
  function onBulkConfirmOpen(open: boolean) {
    if (!open && !s.bulkBusy.value) s.bulkConfirm.value = ''
  }
  return { onBulkAct, onBulkConfirmOpen, ...useBulkCalls(o, s, runBulkCalls) }
}

function useBulkCalls(o: IssueBulkOpts, s: BulkState, runBulkCalls: (fn: (key: string) => Promise<void>) => Promise<void>) {
  async function runBulkConfirm() {
    const action = s.bulkConfirm.value
    if (!action) return
    /* the archive path of c-241 (5913daef1): a row takes its sub-issues along */
    await runBulkCalls(async (key) => {
      try {
        const res = action === 'archive'
          ? await withSessionRetry(o.api, () => o.api.archiveIssue(key, { cascade: true }))
          : await withSessionRetry(o.api, () => o.api.deleteIssue(key, { cascade: true }))
        o.dropKeys([key, ...((res.descendants as string[] | undefined) || [])])
      } catch (e) {
        /* gone with a parent checked in the same run */
        if (Number((e as { status?: number })?.status) !== 404) throw e
        o.dropKeys([key])
      }
    })
    s.bulkConfirm.value = ''
  }
  /* Status / Assignee / Move to on every checked row. An epic or feature does
     not move under an epic: it is named as not changed, never demoted. */
  async function runBulkPatch(kind: string, value: string) {
    let body: Record<string, unknown> | null = null
    if (kind === 'status') body = { status: value }
    else if (kind === 'assign') body = { assignee: value }
    else if (kind === 'move-epic') body = { kind: 'issue', parent: value }
    if (!body) return
    const patch = body
    await runBulkCalls(async (key) => {
      const row = o.issues.value.find((i) => i.key === key)
      if (kind === 'move-epic' && (!row || isTopKind(row.kind) || key === value)) throw new Error('not movable')
      const data = await withSessionRetry(o.api, () => o.api.updateIssue(key, patch))
      o.keepOrDrop(key, data)
    })
  }
  return { runBulkConfirm, runBulkPatch }
}
