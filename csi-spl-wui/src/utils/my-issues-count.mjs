/**
 * The Issues rail count: how many open issues are assigned to the viewer
 * (owner HUM-10, t1 de3c2cf5 msg 26c89f60: an unanswered blocker "should
 * increase the counter on the issues. Whenever the person goes on the issue,
 * he will see how many things he will have to do"). Loaded by ChannelSidebar
 * with a dynamic import once signed in, so it never rides the initial JS.
 * Node tests import this file.
 */

/** Every status but done and diss (discarded) is still something to do. */
export const OPEN_ISSUE_STATUSES = Object.freeze(['eval', 'todo', 'wip', 'blocked', 'onhold', 'qas'])

/** How many of issues are open; a level-1 row (epic / feature) is not a task. */
export function openIssueCount(issues) {
  if (!Array.isArray(issues)) return 0
  return issues.filter((i) => i && OPEN_ISSUE_STATUSES.includes(String(i.status || ''))
    && i.kind !== 'epic' && i.kind !== 'feature').length
}

/**
 * Keeps count.value at the viewer's open assigned issues: one read now, and
 * one after any issue frame or a reconnect (frames come in bursts, so a
 * re-read waits `delay` ms for the last of them). Returns a stop function.
 */
export function startMyIssuesCount({ api, live, count, delay = 1000 }) {
  let timer = null
  let stopped = false
  const load = async () => {
    try {
      const data = await api.listIssues({ filter: { assignee: ['me'] } })
      if (!stopped) count.value = openIssueCount(data && data.issues)
    } catch { /* the count keeps its last value */ }
  }
  const soon = () => {
    clearTimeout(timer)
    timer = setTimeout(load, delay)
  }
  const offs = [live?.onIssue?.(soon), live?.onReconnected?.(soon)]
  void load()
  return () => {
    stopped = true
    clearTimeout(timer)
    for (const off of offs) if (typeof off === 'function') off()
  }
}
