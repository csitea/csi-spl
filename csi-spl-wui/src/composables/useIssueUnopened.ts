import type { Ref } from 'vue'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { normalizeIssue, unopenedCandidate, type Issue } from '~/utils/issues.mjs'
import { ISSUE_OPENED_EVENT } from '~/utils/my-issues-count.mjs'
import type { IssuesApi } from '~/composables/issuesPageTypes'

/**
 * SPL-1559 (owner t1 7edebc75): a new issue keeps the unread row's mark until
 * it is opened. Opening clears it at once, tells the hub, and asks the Issues
 * tab count to re-read; a refused write puts the mark back.
 * Moved out of pages/issues.vue (r16-07); the page owns the refs.
 */
export type IssueUnopenedOpts = {
  api: IssuesApi
  issues: Ref<Issue[]>
  detail: Ref<Issue | null>
  meId: () => string
}

export function useIssueUnopened(o: IssueUnopenedOpts) {
  function setUnopened(key: string, on: boolean) {
    o.issues.value = o.issues.value.map((i) => (i.key === key && i.unopened !== on ? { ...i, unopened: on } : i))
  }
  async function markOpened(issue: Issue | null) {
    if (!issue || !issue.unopened) return
    issue.unopened = false
    setUnopened(issue.key, false)
    try {
      await withSessionRetry(o.api, () => o.api.markIssueOpened(issue.key))
      window.dispatchEvent(new Event(ISSUE_OPENED_EVENT))
    } catch {
      setUnopened(issue.key, true)
    }
  }
  /* SPL-1559: a frame carries no viewer's mark. A row that just became mine to
     do (new, reassigned to me, reopened) asks the hub whether I opened it. */
  async function checkUnopened(before: Issue[], frame: unknown) {
    const key = String((frame as { issue?: { key?: string } })?.issue?.key || '')
    const me = o.meId()
    const row = o.issues.value.find((i) => i.key === key)
    const was = before.find((i) => i.key === key)
    if (!row || !unopenedCandidate(row, me) || (was && unopenedCandidate(was, me))) return
    try {
      const data = await withSessionRetry(o.api, () => o.api.getIssue(key))
      if (!normalizeIssue(data.issue).unopened) return
      if (o.detail.value?.key === key) void markOpened({ ...row, unopened: true })
      else setUnopened(key, true)
    } catch { /* the next list read brings the mark */ }
  }
  return { setUnopened, markOpened, checkUnopened }
}
