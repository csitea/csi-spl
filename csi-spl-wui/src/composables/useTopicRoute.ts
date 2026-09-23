import type { SpoolMessage } from '~/types/spool'
import { useTopicStore, type TopicTarget } from '~/stores/topic'
import { queryWithTopic, sameQuery, sameTarget, targetFromQuery, topicTargetFor } from '~/utils/topic-open.mjs'

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

  /* pane -> URL */
  watch(() => topic.target, (t) => {
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
