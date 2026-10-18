import type { ComputedRef, Ref } from 'vue'
import type { Router, RouteLocationNormalizedLoaded } from 'vue-router'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { normalizeIssue, type Issue } from '~/utils/issues.mjs'
import type { IssuePickerMenu, IssuesApi } from '~/composables/issuesPageTypes'

/**
 * Opening and closing an issue, and the ?issue= entry that goes with it.
 * Moved out of pages/issues.vue (r13-06); the page owns the refs.
 */
export type IssueOpenOpts = {
  api: IssuesApi
  route: RouteLocationNormalizedLoaded
  router: Router
  phone: ComputedRef<boolean>
  modalOpen: ComputedRef<boolean>
  issues: Ref<Issue[]>
  detail: Ref<Issue | null>
  creating: Ref<boolean>
  openKey: Ref<string>
  cursorKey: Ref<string>
  menu: Ref<IssuePickerMenu | null>
  saveError: Ref<string>
  failKey: (e: unknown) => string
  hold: (issue: Issue) => void
}

export function currentQuery(): Record<string, string> {
  const query: Record<string, string> = {}
  new URL(window.location.href).searchParams.forEach((v, k) => { query[k] = v })
  return query
}

function issueLinkKey(route: RouteLocationNormalizedLoaded): string {
  if (import.meta.client) {
    try { return new URL(window.location.href).searchParams.get('issue')?.trim() || '' } catch { /* use the route */ }
  }
  const q = route.query.issue
  const raw = Array.isArray(q) ? q[0] : q
  return typeof raw === 'string' ? raw.trim() : ''
}

/* SPL-1027: above 820 px opening an issue is a history entry (?issue=SPL-n),
   so Back closes the modal and a deep link opens it. A phone keeps
   replaceState: useMobileStack owns its levels and history (SPL-992). */
function useIssueQuery(o: IssueOpenOpts) {
  const h = {
    pushedIssue: false,
    /* the router writes ?issue= a tick (or, on a loaded machine, much longer)
       after the modal shows: a close inside that window waits for the push to
       land, then steps Back over it, and the late route change must not reopen
       what was just closed */
    pendingPush: null as Promise<unknown> | null,
    suppressKey: '',
  }
  function writeIssueQuery(key: string) {
    if (!import.meta.client) return
    const url = new URL(window.location.href)
    if ((url.searchParams.get('issue') || '') === key) return
    /* SPL-1027: > 820 px Back and Forward walk these entries, so the router's
       own record of each must match its URL - a bare replaceState kept the
       router's old path and a later Back brought a closed ?issue= back */
    if (!o.phone.value) {
      const query = currentQuery()
      if (key) query.issue = key
      else delete query.issue
      void o.router.replace({ query })
      return
    }
    if (key) url.searchParams.set('issue', key)
    else url.searchParams.delete('issue')
    window.history.replaceState(window.history.state, '', url.pathname + url.search + url.hash)
  }
  function pushIssueQuery(key: string) {
    if (!import.meta.client) return
    if (o.phone.value || o.modalOpen.value || issueLinkKey(o.route) === key) { writeIssueQuery(key); return }
    h.pushedIssue = true
    const push = o.router.push({ query: { ...currentQuery(), issue: key } })
    h.pendingPush = push
    void push.finally(() => { if (h.pendingPush === push) h.pendingPush = null })
  }
  return { h, writeIssueQuery, pushIssueQuery }
}

export function useIssueOpen(o: IssueOpenOpts) {
  const { h, writeIssueQuery, pushIssueQuery } = useIssueQuery(o)
  /* P5-06: a sheet row carries no description (the hub's list projects only
     what the sheet paints), so opening one reads the issue by number first and
     the modal paints the whole issue, never a blank description. `loaded` = the
     caller already holds that read. The last open wins a race. */
  let chooseSeq = 0
  function choose(issue: Issue, fromLink = false, loaded = false) {
    const seq = ++chooseSeq
    if (loaded) { show(issue, fromLink); return }
    o.cursorKey.value = issue.key
    void withSessionRetry(o.api, () => o.api.getIssue(issue.key)).then(
      (data) => { if (seq === chooseSeq) show(normalizeIssue(data.issue), fromLink) },
      (e) => { if (seq === chooseSeq) o.saveError.value = o.failKey(e) },
    )
  }
  function show(issue: Issue, fromLink: boolean) {
    const wasOpen = o.modalOpen.value
    o.cursorKey.value = issue.key
    o.creating.value = false
    o.openKey.value = issue.key
    o.menu.value = null
    if (fromLink || wasOpen) writeIssueQuery(issue.key)
    else pushIssueQuery(issue.key)
    o.detail.value = issue
  }
  function closeDetail() {
    chooseSeq++ /* an open still loading stays closed */
    const wasModal = o.modalOpen.value
    const closedKey = o.detail.value?.key || ''
    o.creating.value = false
    o.openKey.value = ''
    o.detail.value = null
    o.menu.value = null
    if (wasModal && h.pushedIssue && h.pendingPush) {
      h.pushedIssue = false
      h.suppressKey = closedKey
      void h.pendingPush.then(() => { if (issueLinkKey(o.route)) o.router.back() }, () => { h.suppressKey = '' })
      return
    }
    if (wasModal && h.pushedIssue && issueLinkKey(o.route)) {
      h.pushedIssue = false
      o.router.back()
      return
    }
    h.pushedIssue = false
    writeIssueQuery('')
  }
  const links = useIssueLinks(o, choose)
  watchIssueRoute(o, h, links.openLinkedIssue)
  /* a new issue or an open the page starts itself (startCreate) */
  function cancelOpen() { chooseSeq++ }
  return { choose, closeDetail, writeIssueQuery, cancelOpen, ...links }
}

function useIssueLinks(o: IssueOpenOpts, choose: (issue: Issue, fromLink?: boolean, loaded?: boolean) => void) {
  async function openIssueKey(key: string) {
    if (!key) return
    const held = o.issues.value.find((i) => i.key === key)
    if (held) { choose(held); return }
    try {
      const data = await withSessionRetry(o.api, () => o.api.getIssue(key))
      choose(normalizeIssue(data.issue), false, true)
    } catch (e) {
      o.saveError.value = o.failKey(e)
    }
  }
  async function openLinkedIssue() {
    const key = issueLinkKey(o.route)
    if (!key) return
    if (o.detail.value && o.detail.value.key.toLowerCase() === key.toLowerCase()) return
    const held = o.issues.value.find((i) => i.key.toLowerCase() === key.toLowerCase())
    if (held) { choose(held, true); return }
    try {
      const data = await withSessionRetry(o.api, () => o.api.getIssue(key))
      const issue = normalizeIssue(data.issue)
      o.hold(issue)
      choose(issue, true, true)
    } catch {
      /* an unknown key opens nothing */
    }
  }
  return { openIssueKey, openLinkedIssue }
}

function watchIssueRoute(o: IssueOpenOpts, h: { pushedIssue: boolean, suppressKey: string }, openLinkedIssue: () => Promise<void>) {
  watch(() => {
    const q = o.route.query.issue
    const raw = Array.isArray(q) ? q[0] : q
    return typeof raw === 'string' ? raw.trim() : ''
  }, (key) => {
    /* the push of an issue closed before it landed: not a request to open it */
    if (key && h.suppressKey && key.toLowerCase() === h.suppressKey.toLowerCase()) { h.suppressKey = ''; return }
    if (!key) h.suppressKey = ''
    /* SPL-1027: Back past the entry the modal pushed closes it */
    if (!key && o.modalOpen.value) {
      h.pushedIssue = false
      o.openKey.value = ''
      o.detail.value = null
      o.menu.value = null
      return
    }
    void openLinkedIssue()
  })
}
