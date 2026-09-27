import type { SpoolMessage } from '~/types/spool'
import { useTopicStore, type TopicTarget } from '~/stores/topic'
import { queryWithTopic, sameQuery, sameTarget, targetFromQuery, topicFeedRelease, topicTargetFor } from '~/utils/topic-open.mjs'

/**
 * CLE-3427 — the open topic and the URL, kept as one fact.
 *
 * The page says how to open a target (the two panes read different stores)
 * and this keeps `?topic=` / `?in=` in step with it both ways: a click
 * writes the URL, and the URL — a deep link, a reload, Back / Forward —
 * opens the pane. `replace` rather than `push`, so reading five messages in a
 * row does not bury the page the reader came from under five history entries.
 */
export function useTopicRoute(opts: {
  /** open this target; `root` is the clicked row when there was one */
  open: (target: TopicTarget, root: SpoolMessage | null) => void | Promise<void>
  close: () => void
  /** the task this feed itself shows (a lobby row's topic is the row, not the feed) */
  currentTaskId?: () => string
  /** where a deep link looks for the pinned root it was not handed */
  rowFor?: (msgId: string) => SpoolMessage | null | undefined
}) {
  const route = useRoute()
  const router = useRouter()
  const topic = useTopicStore()

  /* URL -> pane: the first render, a reload, Back and Forward */
  watch(() => [route.query.topic, route.query.in] as const, () => {
    const want = targetFromQuery(route.query) as TopicTarget | null
    if (sameTarget(want, topic.target)) return
    if (!want) return void opts.close()
    void opts.open(want, (opts.rowFor && opts.rowFor(want.rootMsgId)) || null)
  }, { immediate: true })

  /* pane -> URL. Only while this page IS the current route: during a
     navigation Nuxt keeps the old page mounted until the new one is ready,
     and the new page closing the topic would otherwise make the OLD page
     write its own query onto the NEW path (SPL-1005: `/search x` typed with
     a thread open landed on /search with no q) */
  watch(() => topic.target, (t) => {
    if (router.currentRoute.value.path !== route.path) return
    const query = queryWithTopic(route.query, t)
    if (sameQuery(query, route.query)) return
    void router.replace({ query })
  })

  /** A clicked row: which topic that is, then open it. */
  function openRow(msg: SpoolMessage) {
    const target = topicTargetFor(msg, { currentTaskId: opts.currentTaskId ? opts.currentTaskId() : '' }) as TopicTarget | null
    if (!target) return
    void opts.open(target, msg)
  }

  return { openRow }
}

/**
 * Close the topic pane when the feed now on screen does not contain its task.
 *
 * `ready` stays false until that feed has loaded. Judging earlier would
 * compare the new person or channel with the previous list and close a deep
 * link that does belong here. A card click still opens through openRow;
 * this only closes a task the loaded list does not name.
 */
export function useTopicFeedClose(opts: {
  ready: () => boolean
  messages: () => readonly unknown[]
}) {
  const route = useRoute()
  const router = useRouter()
  const topic = useTopicStore()
  let releasing = false

  /* The store's task, or the URL's ?topic= when the store is already clear,
     so a stale deep link is dropped with the pane. */
  function openTopicId(): string {
    const fromStore = topic.parentTaskId || (topic.target ? topic.target.taskId : '')
    const raw = route.query.topic
    const fromUrl = Array.isArray(raw) ? raw[0] : raw
    return String(fromStore || fromUrl || '')
  }

  function releaseStaleTopic() {
    if (releasing || !opts.ready()) return
    const plan = topicFeedRelease(openTopicId(), opts.messages(), route.query)
    if (!plan.close) return
    releasing = true
    try {
      topic.close()
      if (plan.query) void router.replace({ query: plan.query })
    } finally {
      releasing = false
    }
  }

  /* A stale ?topic= can reopen the pane after the feed loaded (the route
     watcher applies the query). Close that task again before it paints. */
  watch(() => topic.parentTaskId, () => releaseStaleTopic(), { flush: 'sync' })

  return { releaseStaleTopic }
}
