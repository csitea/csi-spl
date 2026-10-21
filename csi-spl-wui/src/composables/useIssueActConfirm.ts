import type { ComputedRef, Ref } from 'vue'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { isTopKind, type EpicSummary, type Issue } from '~/utils/issues.mjs'
import { useIssueMenu, type IssueMenuTarget } from '~/composables/useIssueMenu'
import type { IssuePickerMenu, IssuesApi } from '~/composables/issuesPageTypes'
import { useArchiveUndo } from '~/composables/useArchiveUndo'

/**
 * The single-issue delete confirm and the shared archive / delete confirm
 * (SPL-1226: an epic, a feature or an issue with sub-issues takes its subtree
 * along). Moved out of pages/issues.vue (r13-06).
 */
type HubErr = { status?: number, token?: string }
export type IssueActConfirmOpts = {
  api: IssuesApi
  t: (key: string, named?: Record<string, unknown>, plural?: number) => string
  issues: Ref<Issue[]>
  subtasks: Ref<Issue[]>
  epics: Ref<EpicSummary[]>
  detail: Ref<Issue | null>
  cursorKey: Ref<string>
  flat: ComputedRef<Issue[]>
  menu: Ref<IssuePickerMenu | null>
  closeDetail: () => void
  refreshEpics: () => void
  errorKey: (err: HubErr, which: 'list' | 'one') => string
  refusedText: (key: string, e: unknown) => string
  /* SPL-2783: the page's phone check (useMobileStack) and its list re-read */
  phone: Ref<boolean> | ComputedRef<boolean>
  reload: () => Promise<void>
}
type ActConfirm = { target: IssueMenuTarget, action: 'archive' | 'delete', count: number }

export function issueTarget(i: Issue): IssueMenuTarget {
  return { key: i.key, kind: i.kind, level: i.level, title: i.title, top: isTopKind(i.kind), parent: i.parent || '' }
}

/* the confirm's error text. A cascade archive/delete hits endpoints a hub
   older than SPL-1226 does not have: POST .../archive is 404/405, and
   DELETE ?cascade=1 is ignored so a parent comes back 409 issue_has_children.
   Both must read as "the server is not updated yet", never a silent no-op or
   the misleading "move its issues first" (CLE-001, owner b82f3853). */
function actErrorKey(o: IssueActConfirmOpts, err: HubErr, cascade: boolean) {
  const s = Number(err?.status)
  if (s === 404 || s === 405 || s === 501) return 'issues_menu.err_unavailable'
  if (cascade && err?.token === 'issue_has_children') return 'issues_menu.err_unavailable'
  if (s === 403) return 'issues_crud.err_delete_forbidden'
  return o.errorKey(err, 'one')
}
function deleteErrKey(o: IssueActConfirmOpts, err: HubErr) {
  if (err?.token === 'issue_has_children') return 'issues_crud.err_has_children'
  if (Number(err?.status) === 403) return 'issues_crud.err_delete_forbidden'
  return o.errorKey(err, 'one')
}

export function useIssueActConfirm(o: IssueActConfirmOpts) {
  const actConfirm = ref<ActConfirm | null>(null)
  const actBusy = ref(false)
  const actError = ref('')
  const counts = useSubCounts(o)
  function askAction(action: 'archive' | 'delete', tg: IssueMenuTarget) {
    useIssueMenu().close()
    actError.value = ''
    const count = counts.descendantCount(tg)
    /* SPL-2783 (owner, t1 ff23df68 f702164e): "On mobile there is no need to
       confirm archiving". One issue on a phone archives at once, with the
       Archived · Undo toast; a cascade (an epic, sub-issues) still asks. */
    if (action === 'archive' && o.phone.value && !tg.top && count === 0) { void run.archiveNow(tg); return }
    actConfirm.value = { target: tg, action, count }
    if (tg.top || count > 0) return
    /* not loaded here: ask the hub, so the confirm states them before the call
       (still this ask: the ref holds a proxy, so compare by key, not identity) */
    void counts.probeSubCount(tg.key).then((n) => {
      const c = actConfirm.value
      if (n > 0 && c && c.target.key === tg.key && c.action === action && c.count === 0 && !actBusy.value) actConfirm.value = { ...c, count: n }
    })
  }
  function onActConfirmOpen(open: boolean) {
    if (!open && !actBusy.value) actConfirm.value = null
  }
  const act = { actConfirm, actBusy, actError }
  const run = useRunAction(o, act, counts.probeSubCount)
  const del = useDeleteConfirm(o, { ...act, ...counts, askAction })
  return { ...act, askAction, onActConfirmOpen, ...run, ...del, loadedSubCount: counts.loadedSubCount }
}

function useSubCounts(o: IssueActConfirmOpts) {
  /* the count the confirm states: for an epic / feature the issues under it, else
     the subtasks held under it. Counted from the loaded list (immediate, in step
     with what is shown); the epics summary is a fallback for when the list is
     filtered to another epic (the summary read is debounced, so it can lag). */
  function descendantCount(tg: IssueMenuTarget): number {
    if (tg.top) {
      const inList = o.issues.value.filter((i) => i.epic === tg.key).length
      return Math.max(inList, o.epics.value.find((e) => e.key === tg.key)?.total || 0)
    }
    return loadedSubCount(tg.key)
  }
  /* HUM-10 (t1 40c135cb): an issue's live sub-issues - the open issue's are
     loaded (subtasks), a list row's children may be; else the hub is asked */
  function loadedSubCount(key: string): number {
    const open = o.detail.value?.key === key ? o.subtasks.value.length : 0
    return Math.max(open, o.issues.value.filter((i) => i.parent === key).length)
  }
  async function probeSubCount(key: string): Promise<number> {
    try {
      const data = await withSessionRetry(o.api, () => o.api.listIssues({ filter: { parent: [key] } }))
      return Math.max(Number((data as { total?: number }).total) || 0, (data.issues || []).length)
    } catch {
      return 0
    }
  }
  return { descendantCount, loadedSubCount, probeSubCount }
}

type ActState = { actConfirm: Ref<ActConfirm | null>, actBusy: Ref<boolean>, actError: Ref<string> }

function dropGone(o: IssueActConfirmOpts, gone: Set<string>) {
  o.issues.value = o.issues.value.filter((i) => !gone.has(i.key))
  o.subtasks.value = o.subtasks.value.filter((i) => !gone.has(i.key))
  o.refreshEpics()
  if (o.detail.value && gone.has(o.detail.value.key)) o.closeDetail()
}

function dropAndMove(o: IssueActConfirmOpts, gone: Set<string>) {
  dropGone(o, gone)
  if (o.cursorKey.value && gone.has(o.cursorKey.value)) o.cursorKey.value = o.flat.value[0]?.key || ''
}

function useRunAction(o: IssueActConfirmOpts, s: ActState, probeSubCount: (key: string) => Promise<number>) {
  /* SPL-2783: the phone's archive with no confirm. A refusal opens the
     confirm after all: the cascade offer when it has sub-issues the list did
     not know of, else the error - never a silent no-op. */
  async function archiveNow(tg: IssueMenuTarget) {
    if (s.actBusy.value) return
    s.actBusy.value = true
    try {
      await withSessionRetry(o.api, () => o.api.archiveIssue(tg.key, { cascade: false }))
      dropAndMove(o, new Set([tg.key]))
      useArchiveUndo().offerRestore(async () => {
        await withSessionRetry(o.api, () => o.api.unarchiveIssue(tg.key))
        await o.reload()
      })
    } catch (e) {
      const n = (e as HubErr)?.token === 'issue_has_children' ? await probeSubCount(tg.key) : 0
      s.actConfirm.value = { target: tg, action: 'archive', count: n }
      if (n === 0) s.actError.value = o.refusedText(actErrorKey(o, e as HubErr, false), e)
    } finally {
      s.actBusy.value = false
    }
  }
  async function runAction() {
    const c = s.actConfirm.value
    if (!c || s.actBusy.value) return
    s.actBusy.value = true
    s.actError.value = ''
    /* a level-1 row (or one with children) takes its subtree with it */
    const cascade = c.target.top || c.count > 0
    try {
      const res = c.action === 'archive'
        ? await withSessionRetry(o.api, () => o.api.archiveIssue(c.target.key, { cascade }))
        : await withSessionRetry(o.api, () => o.api.deleteIssue(c.target.key, { cascade }))
      dropAndMove(o, new Set<string>([c.target.key, ...((res.descendants as string[] | undefined) || [])]))
      s.actConfirm.value = null
    } catch (e) {
      /* HUM-10: refused for sub-issues it did not know of: the confirm turns
         into the cascade offer, the count in its button */
      if (!cascade && (e as HubErr)?.token === 'issue_has_children') {
        const n = await probeSubCount(c.target.key)
        if (n > 0 && s.actConfirm.value === c) { s.actConfirm.value = { ...c, count: n }; return }
      }
      /* keep the confirm open with a clear message - never a silent no-op */
      s.actError.value = o.refusedText(actErrorKey(o, e as HubErr, cascade), e)
    } finally {
      s.actBusy.value = false
    }
  }
  const actConfirmLabel = computed(() => {
    const c = s.actConfirm.value
    const verb = c && c.action === 'archive' ? 'archive' : 'delete'
    /* HUM-10: one confirm, the sub-issue count in its button */
    if (c && c.count > 0 && !c.target.top) return o.t(`issues_menu.${verb}_with_subs`, { count: c.count }, c.count)
    return o.t(verb === 'archive' ? 'issues_menu.archive' : 'issues_crud.delete')
  })
  const actConfirmTitleKey = computed(() => {
    const c = s.actConfirm.value
    if (!c) return ''
    if (c.count > 0 && c.target.top) return c.action === 'archive' ? 'issues_menu.archive_cascade_title' : 'issues_menu.delete_cascade_title'
    return c.action === 'archive' ? 'issues_menu.archive_title' : 'issues_menu.delete_title'
  })
  return { runAction, archiveNow, actConfirmLabel, actConfirmTitleKey }
}

type DeleteDeps = ActState & {
  loadedSubCount: (key: string) => number
  probeSubCount: (key: string) => Promise<number>
  askAction: (action: 'archive' | 'delete', tg: IssueMenuTarget) => void
}

function useDeleteConfirm(o: IssueActConfirmOpts, d: DeleteDeps) {
  const delTarget = ref<Issue | null>(null)
  const delBusy = ref(false)
  const delError = ref('')
  function askDelete(issue: Issue) {
    o.menu.value = null
    /* HUM-10: an issue with live sub-issues asks the cascade confirm instead */
    if (!isTopKind(issue.kind) && d.loadedSubCount(issue.key) > 0) { d.askAction('delete', issueTarget(issue)); return }
    delError.value = ''
    delTarget.value = issue
  }
  function onDeleteOpen(open: boolean) {
    if (!open && !delBusy.value) delTarget.value = null
  }
  async function confirmDelete() {
    const issue = delTarget.value
    if (!issue || delBusy.value) return
    delBusy.value = true
    delError.value = ''
    try {
      await withSessionRetry(o.api, () => o.api.deleteIssue(issue.key))
      const at = o.flat.value.findIndex((i) => i.key === issue.key)
      dropGone(o, new Set([issue.key]))
      if (o.cursorKey.value === issue.key) o.cursorKey.value = o.flat.value[Math.min(at, o.flat.value.length - 1)]?.key || ''
      delTarget.value = null
    } catch (e) {
      /* HUM-10: refused for live sub-issues the list did not know of: offer the cascade */
      if ((e as HubErr)?.token === 'issue_has_children') {
        const n = await d.probeSubCount(issue.key)
        if (n > 0) {
          delTarget.value = null
          d.actError.value = ''
          d.actConfirm.value = { target: issueTarget(issue), action: 'delete', count: n }
          return
        }
      }
      delError.value = o.refusedText(deleteErrKey(o, e as HubErr), e)
    } finally {
      delBusy.value = false
    }
  }
  return { delTarget, delBusy, delError, askDelete, onDeleteOpen, confirmDelete }
}
