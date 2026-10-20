import type { ComputedRef, Ref } from 'vue'
import type { Router, RouteLocationNormalizedLoaded } from 'vue-router'
import { ISSUE_STATUSES, type EpicSummary, type Issue, type IssueFilter } from '~/utils/issues.mjs'
import { isNewIssue } from '~/utils/my-issues-count.mjs'
import { type IssuesView } from '~/utils/view-prefs.mjs'
import { controlLabel, groupIssues, hubOrder, localInputToDeadline, nextSort, sortDirKey, sortFromQuery, sortSheet } from '~/utils/issues-view.mjs'
import { currentQuery } from '~/composables/useIssueOpen'
import type { IssueMenuTarget } from '~/composables/useIssueMenu'
import { useViewPrefs } from '~/composables/useViewPrefs'
import { useIssueUnreadOrder } from '~/composables/useIssueUnreadOrder'

/**
 * The Issues page's filter and sort state: the filter row, the phone's
 * filter and sort sheets, ?sort=&dir=, ?unread=1 and ?epic=, and the filter
 * the hub reads, and the rows the sheet shows from them (the view, the
 * status groups and their folds). Moved out of pages/issues.vue (r15-01); a
 * change of any filter or of the sort calls `reload`.
 */
export type IssueSortState = { col: string, dir: string }
export type IssueFiltersOpts = {
  route: RouteLocationNormalizedLoaded
  router: Router
  t: (key: string, named?: Record<string, unknown>) => string
  /* the person's per-tenant default sort (issues_sort claim, SPL-1181) */
  storedSort: () => IssueSortState | null | undefined
  people: () => { id: string }[]
  person: (id: string) => string
  epics: Ref<EpicSummary[]>
  reload: () => void
  issues: Ref<Issue[]>
  phone: ComputedRef<boolean>
  signedIn: () => boolean
  meId: () => string
  labelText: (id: string) => string
}

/* owner, topics e65c0f60 + e00da93b + 3a589b54: one flat list, sorted by a
   header click; the sort lives in ?sort=&dir=. With no ?sort= the list opens
   with the person's PER-TENANT default (issues_sort claim, SPL-1181), else the
   product default (priority ascending, applied by sortSheet/hubOrder). */
function initialSort(o: IssueFiltersOpts): IssueSortState {
  const q = sortFromQuery(o.route.query as Record<string, unknown>)
  if (q.col) return q
  const stored = o.storedSort()
  if (stored && stored.col && stored.dir) return sortFromQuery({ sort: stored.col, dir: stored.dir })
  return { col: '', dir: '' }
}

/* t1 27b3ab77: ?unread=1, the issues the Issues tab badge counts (a tap on
   the badge opens the list with it on); the query follows the filter, and
   the badge's link sets the filter */
function useUnreadFilter(o: IssueFiltersOpts) {
  const unreadOn = () => String(o.route.query.unread || '') === '1'
  const unreadF = ref(unreadOn())
  watch(() => o.route.query.unread, () => { unreadF.value = unreadOn() })
  watch(unreadF, (on) => {
    if (!import.meta.client || on === unreadOn()) return
    const query = currentQuery()
    if (on) query.unread = '1'
    else delete query.unread
    void o.router.replace({ query })
  })
  return unreadF
}

function useEpicFilter(o: IssueFiltersOpts) {
  const epicF = computed(() => {
    const q = o.route.query.epic
    const raw = Array.isArray(q) ? q[0] : q
    return typeof raw === 'string' ? raw.trim().toUpperCase() : ''
  })
  const epicTitle = computed(() => o.epics.value.find((e) => e.key === epicF.value)?.title || '')
  /* owner b82f3853: the epic/feature the view is filtered to (?epic=), as a menu
     target for the title-row actions button. null when the view is not filtered
     to one epic - then the button is disabled with a tooltip. A level-1 top row;
     the kind comes from the epics summary (epic vs feature), defaulting to epic. */
  const selectedEpic = computed<IssueMenuTarget | null>(() => {
    const key = epicF.value
    if (!key) return null
    const e = o.epics.value.find((x) => x.key === key)
    return { key, kind: e?.kind || 'epic', level: 1, title: e?.title || key, top: true }
  })
  function epicLabel(key: string) {
    const e = o.epics.value.find((x) => x.key === key)
    return e ? `${e.key} ${e.title}` : key
  }
  function epicTitleOf(key: string) {
    return o.epics.value.find((x) => x.key === key)?.title || key
  }
  /* an epic chip is the side panel's epic row: ?epic= on the same entry */
  function pickEpic(key: string) {
    const query = currentQuery()
    if (key) query.epic = key
    else delete query.epic
    void o.router.replace({ query })
  }
  return { epicF, epicTitle, selectedEpic, epicLabel, epicTitleOf, pickEpic }
}

function useSheetSort(o: IssueFiltersOpts) {
  const { t } = o
  const sheetSort = ref<IssueSortState>(initialSort(o))
  const sortOpen = ref(false)
  const sheetColumns = computed(() => [
    { col: 'key', name: t('issues_view.col_key'), cls: 'issues-c-key' },
    { col: 'title', name: t('issues_view.col_title'), cls: 'issues-c-title' },
    { col: 'status', name: t('issues.filter_status'), cls: '' },
    { col: 'priority', name: t('issues.filter_priority'), cls: '' },
    { col: 'level', name: t('issues.filter_level'), cls: '' },
    { col: 'assignee', name: t('issues.filter_assignee'), cls: '' },
    { col: 'label', name: t('issues.filter_label'), cls: '' },
    { col: 'deadline', name: t('issues.field_deadline'), cls: '' },
    { col: 'updated', name: t('issues.sort_updated'), cls: '' },
  ])
  /* t1 d5d00918: the hub pages in the sheet's own column and direction */
  const serverOrder = computed(() => hubOrder(sheetSort.value))
  const serverOrderKey = computed(() => `${serverOrder.value.sort}:${serverOrder.value.dir}`)
  function toggleSort(col: string) {
    sheetSort.value = nextSort(col, sheetSort.value)
  }
  watch(sheetSort, (v) => {
    if (!import.meta.client) return
    const url = new URL(window.location.href)
    if (v.col) { url.searchParams.set('sort', v.col); url.searchParams.set('dir', v.dir) }
    else { url.searchParams.delete('sort'); url.searchParams.delete('dir') }
    window.history.replaceState(window.history.state, '', url.pathname + url.search + url.hash)
  })
  /* SPL-1596 (owner, t1 27b3ab77): each column once; the direction is said in
     words ("Deadline, oldest first") and flipped by Reverse, never listed twice */
  const sortChoices = computed(() => [
    { value: '', label: t('issues_mobile.sort_default') },
    ...sheetColumns.value.map((c) => ({ value: c.col, label: c.name })),
  ])
  const sortValue = computed(() => `${sheetSort.value.col}:${sheetSort.value.dir}`)
  const sortWords = computed(() => {
    const s = sheetSort.value
    const c = sheetColumns.value.find((x) => x.col === s.col)
    return c ? t('issues_mobile.sort_now', { col: c.name, dir: t(sortDirKey(s.col, s.dir)) }) : t('issues_mobile.sort_default')
  })
  /* a new column starts ascending (as a header click); the same column keeps its direction */
  function pickSort(col: string, dir = '') {
    const cur = sheetSort.value
    sheetSort.value = sortFromQuery({ sort: col, dir: dir || (cur.col === col ? cur.dir : 'asc') })
    sortOpen.value = false
  }
  return { sheetSort, sortOpen, sheetColumns, serverOrder, serverOrderKey, toggleSort, sortChoices, sortValue, sortWords, pickSort }
}

/* the assignee filter's choices, and the whole closed-control text for the
   hover when it is ellipsized */
function useAssigneeChoices(o: IssueFiltersOpts, assigneeF: Ref<string>) {
  const { t } = o
  const assigneeOptions = computed(() => {
    const seen = new Set<string>()
    const out: { id: string, label: string }[] = []
    for (const p of o.people()) {
      if (!p.id || seen.has(p.id)) continue
      seen.add(p.id)
      out.push({ id: p.id, label: o.person(p.id) })
    }
    return out
  })
  const assigneeTitle = computed(() => {
    const v = assigneeF.value
    const who = !v ? t('issues.filter_all') : v === 'me' ? t('issues.filter_me') : v === 'none' ? t('issues.filter_unassigned') : (assigneeOptions.value.find((p) => p.id === v)?.label || v)
    return controlLabel(t('issues.filter_assignee'), who)
  })
  return { assigneeOptions, assigneeTitle }
}

/* folded status groups: a per-browser convenience (localStorage), not a hub setting */
const FOLD_KEY = 'spool.issues-folded'
function useFolds() {
  const folded = ref<string[]>([])
  function toggleFold(status: string) {
    folded.value = folded.value.includes(status) ? folded.value.filter((s) => s !== status) : [...folded.value, status]
    try { localStorage.setItem(FOLD_KEY, JSON.stringify(folded.value)) } catch { /* private window: this visit only */ }
  }
  onMounted(() => {
    try {
      const raw = JSON.parse(localStorage.getItem(FOLD_KEY) || '[]')
      if (Array.isArray(raw)) folded.value = raw.filter((x): x is string => typeof x === 'string' && (ISSUE_STATUSES as readonly string[]).includes(x))
    } catch { /* none folded */ }
  })
  return { folded, toggleFold }
}

/* SPL-1028: the view. Signed in it is the person's (session claim, rdb 0072);
   signed out (the mock tenant) a click still switches this page. Phones keep
   the card list (SPL-992). */
function useIssueView(o: IssueFiltersOpts) {
  const viewPrefs = useViewPrefs()
  const viewLocal = ref<IssuesView | ''>('')
  const viewBy = computed<IssuesView>(() => {
    if (o.phone.value) return 'list'
    return o.signedIn() ? viewPrefs.issuesView.value : (viewLocal.value || 'list')
  })
  async function pickView(v: IssuesView) {
    if (o.signedIn()) { await viewPrefs.save('issues_view', v); return }
    viewLocal.value = v
  }
  return { viewBy, pickView }
}

/* the rows the sheet shows: the filters, then the sort, then the view's groups */
function useIssueRows(o: IssueFiltersOpts, f: { unreadF: Ref<boolean>, sheetSort: Ref<IssueSortState>, serverFilter: () => IssueFilter }) {
  const unreadIssues = useIssueUnreadOrder() /* SPL-2506: unread issues at the edge new posts go to */
  const { viewBy, pickView } = useIssueView(o)
  const { folded, toggleFold } = useFolds()
  const groups = computed(() => {
    const base = f.unreadF.value ? o.issues.value.filter(isNewIssue) : o.issues.value
    const kept = groupIssues(base, { sort: 'updated', filter: f.serverFilter(), me: o.meId(), by: 'none' })[0].issues
    const rows = unreadIssues(sortSheet(kept, f.sheetSort.value, { name: o.person, labelName: o.labelText }))
    if (viewBy.value !== 'status') return [{ status: '', count: rows.length, issues: rows }]
    /* Linear's "group by status": every status in the workflow order, its
       count, the sheet's sort inside each group; an empty group stays as a drop target */
    return ISSUE_STATUSES.map((status) => {
      const inGroup = rows.filter((i) => i.status === status)
      return { status, count: inGroup.length, issues: inGroup }
    })
  })
  const rowCount = computed(() => groups.value.reduce((n, g) => n + g.count, 0))
  /* the table keeps its header and filter row when nothing matches; the note says so */
  const shownGroups = computed(() => (rowCount.value || viewBy.value === 'status' ? groups.value : []))
  /* J / K walk the rows in the order the sheet shows them */
  const flat = computed(() => groups.value.flatMap((g) => (g.status && folded.value.includes(g.status) ? [] : g.issues)))
  return { viewBy, pickView, folded, toggleFold, groups, rowCount, shownGroups, flat }
}

export function useIssueFilters(o: IssueFiltersOpts) {
  const sort = useSheetSort(o)
  const epic = useEpicFilter(o)
  const { epicF } = epic
  const unreadF = useUnreadFilter(o)
  const statusF = ref('')
  const statusOpen = ref(false)
  const priorityF = ref('')
  const levelF = ref('')
  const assigneeF = ref('')
  const labelF = ref('')
  const dueF = ref('')
  const filtersOpen = ref(false)
  /* every filter the list reads (the bulk bar drops its selection on a change) */
  const filterRefs = [unreadF, statusF, priorityF, levelF, assigneeF, labelF, dueF, epicF]
  const filtersActive = computed(() => Boolean(unreadF.value || statusF.value || priorityF.value || levelF.value || assigneeF.value || labelF.value || dueF.value))
  function serverFilter(): IssueFilter {
    const f: IssueFilter = { kind: 'issue' }
    if (epicF.value) f.epic = [epicF.value]
    if (statusF.value) f.status = [statusF.value]
    if (priorityF.value !== '') f.priority = [Number(priorityF.value)]
    if (levelF.value !== '') f.level = [Number(levelF.value)]
    if (assigneeF.value) f.assignee = [assigneeF.value]
    /* an unread row is always the viewer's: the badge reads the same list */
    else if (unreadF.value) f.assignee = ['me']
    if (labelF.value) f.label = [labelF.value]
    /* one day: issues due on or before its last minute */
    const before = dueF.value ? localInputToDeadline(`${dueF.value}:59`) : ''
    if (before) f.deadlineBefore = before
    return f
  }
  function pickStatus(s: string) {
    statusF.value = s
    statusOpen.value = false
  }
  function clearFilters() {
    sort.sheetSort.value = { col: '', dir: '' }
    unreadF.value = false
    statusF.value = ''
    statusOpen.value = false
    priorityF.value = ''
    levelF.value = ''
    assigneeF.value = ''
    labelF.value = ''
    dueF.value = ''
  }
  watch([...filterRefs, sort.serverOrderKey], () => { o.reload() })
  return {
    ...sort, ...epic, ...useAssigneeChoices(o, assigneeF), ...useIssueRows(o, { unreadF, sheetSort: sort.sheetSort, serverFilter }),
    unreadF, statusF, statusOpen, priorityF, levelF, assigneeF, labelF, dueF,
    filtersOpen, filterRefs, filtersActive, serverFilter, pickStatus, clearFilters,
  }
}
