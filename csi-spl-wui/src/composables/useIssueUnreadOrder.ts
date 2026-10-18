/*
 * SPL-2506 (owner HUM-10, t1 43a1030f): the Issues list puts its issues with
 * unread at the edge new posts go to (useUnreadOrder). An issue's unread is 1
 * while never opened, or more when its topic's hub t: key says so. Its own
 * file: the hub count lives with the lazy topic-card code (useTopicCardNew),
 * which the sidebar's eager useUnreadOrder must not pull in.
 */
import { flowTopicUnread } from '~/composables/useTopicCardNew'
import { useUnreadOrder } from '~/composables/useUnreadOrder'

function issueUnread(issue: { unopened?: boolean, task_id?: string }) {
  return Math.max(issue.unopened ? 1 : 0, flowTopicUnread(String(issue.task_id || '')))
}

export function useIssueUnreadOrder() {
  const { order } = useUnreadOrder()
  return <T extends { unopened?: boolean, task_id?: string, updated_at?: string }>(rows: T[]) => order(rows, issueUnread, (i) => String(i.updated_at || ''))
}
