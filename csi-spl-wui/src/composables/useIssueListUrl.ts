import type { Ref } from 'vue'
import { isNavigationFailure, NavigationFailureType, type Router, type RouteLocationNormalizedLoaded } from 'vue-router'
import { listStateFromQuery, listStateQuery, sameQuery } from '~/utils/issues-list-url'
import type { IssuesView } from '~/utils/view-prefs.mjs'
import { navPending } from '~/utils/nav-pending'
import { currentQuery } from '~/composables/useIssueOpen'

/**
 * SPL-4648: the Issues list's state and its address follow each other, so a
 * copied URL shows the same list to whoever opens it. A URL with `view=` is a
 * complete link: what it does not name is off, the reader's stored choices do
 * not apply. A URL without it (an older link, the Issues tab) takes the stored
 * choices, and the address is then completed with them.
 */
export type IssueListSort = { col: string, dir: string }
export type IssueListState = {
  view: Ref<IssuesView | ''>
  sort: Ref<IssueListSort>
  unread: Ref<boolean>
  status: Ref<string>
  priority: Ref<string>
  level: Ref<string>
  assignee: Ref<string>
  label: Ref<string>
  deadline: Ref<string>
  folded: Ref<string[]>
}
export type IssueListUrlOpts = {
  route: RouteLocationNormalizedLoaded
  router: Router
  state: IssueListState
  /* the stored choices are readable: signed in, the session's claims are here */
  known: () => boolean
  meId: () => string
  stored: { view: () => IssuesView, sort: () => IssueListSort, fold: () => string[] }
}

function readListState(o: IssueListUrlOpts) {
  const { state: st } = o
  /* the address, not the route: closing a phone sheet moves the route to the
     entry under it, and only the address keeps what the sheet wrote (useMobileStack) */
  const url = import.meta.client ? currentQuery() : o.route.query
  const q = listStateFromQuery(url as Record<string, unknown>, o.meId())
  const sort = q.sort.col || q.view ? q.sort : o.stored.sort()
  if (sort.col !== st.sort.value.col || sort.dir !== st.sort.value.dir) st.sort.value = sort
  const fold = q.fold ?? (q.view ? [] : o.stored.fold())
  if (fold.join() !== st.folded.value.join()) st.folded.value = fold
  st.view.value = q.view
  st.unread.value = q.unread
  st.status.value = q.status
  st.priority.value = q.priority
  st.level.value = q.level
  st.assignee.value = q.assignee
  st.label.value = q.label
  st.deadline.value = q.deadline
}

export function useIssueListUrl(o: IssueListUrlOpts) {
  const { state: st } = o
  const path = o.route.path
  /* a replace on its way: the route still names the state before it */
  let writing = 0
  /* the epic a pick or a forget wants; the route says it once the replace lands */
  let epicNext: string | null = null
  /* the state is newer than the address: a navigation cancelled the replace, and it is owed once more */
  let owed = false
  /* a write held back for a move to another page: a replace then would cancel the move */
  let held = false
  const here = () => o.router.currentRoute.value.path === path

  function write() {
    if (!import.meta.client || !here()) return
    const to = navPending()
    if (to && to.path !== path) { held = true; return }
    held = false
    const base = currentQuery()
    if (epicNext !== null) {
      if (epicNext) base.epic = epicNext
      else delete base.epic
    }
    const view = st.view.value || (o.known() ? o.stored.view() : '')
    const next = listStateQuery({
      view, sort: st.sort.value, unread: st.unread.value, status: st.status.value, priority: st.priority.value, level: st.level.value,
      assignee: st.assignee.value, label: st.label.value, deadline: st.deadline.value, fold: st.folded.value,
    }, base, o.meId())
    if (!writing && epicNext === null && sameQuery(next, base)) { owed = false; return }
    writing++
    /* a pick that also closes its phone sheet: the sheet's history.back, or the
       move queued behind it, cancels this replace. Not repeated here (it would
       cancel that navigation in turn, for ever): it stays owed, and follow() or
       the refusal sends it when that navigation has ended */
    const landed = (failure?: unknown) => {
      writing--
      if (writing) return
      if (isNavigationFailure(failure, NavigationFailureType.cancelled)) {
        owed = true
        return
      }
      owed = false
      epicNext = null
      if (!failure) follow()
    }
    o.router.replace({ query: next }).then(landed, landed)
  }

  function setEpic(key: string) {
    epicNext = key
    write()
  }

  /* the address moved (Back, Forward, a link to this page) or the claims arrived */
  function follow() {
    if (writing || !here()) return
    if (!owed) readListState(o)
    write()
  }

  readListState(o)
  if (import.meta.client) {
    /* the move was refused: the address is still owed what changed meanwhile */
    onBeforeUnmount(o.router.afterEach((_to, _from, failure) => {
      /* writing: a replace the move cancelled can report after the refusal */
      if (failure && (held || ((owed || writing) && isNavigationFailure(failure, NavigationFailureType.aborted)))) setTimeout(write, 0)
    }))
    watch(() => o.router.currentRoute.value.query, follow)
    watch(o.known, follow)
    watch([st.view, st.sort, st.unread, st.status, st.priority, st.level, st.assignee, st.label, st.deadline, st.folded, o.meId], write)
    onMounted(write)
  }
  return { setEpic }
}
