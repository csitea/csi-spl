import type { SpoolMessage } from '~/types/spool'
import { useThreadStore, type ThreadTarget } from '~/stores/thread'
import { queryWithThread, sameQuery, sameTarget, targetFromQuery, threadTargetFor } from '~/utils/thread-open.mjs'

/**
 * CLE-3427 — the open thread and the URL, kept as one fact.
 *
 * The page says how to open a target (the two panes read different stores)
 * and this keeps `?thread=` / `?in=` in step with it both ways: a click
 * writes the URL, and the URL — a deep link, a reload, Back / Forward —
 * opens the pane. `replace` rather than `push`, so reading five messages in a
 * row does not bury the page the reader came from under five history entries.
 */
export function useThreadRoute(opts: {
  /** open this target; `root` is the clicked row when there was one */
  open: (target: ThreadTarget, root: SpoolMessage | null) => void | Promise<void>
  close: () => void
  /** the task this feed itself shows (a lobby row's thread is the row, not the feed) */
  currentTaskId?: () => string
  /** where a deep link looks for the pinned root it was not handed */
  rowFor?: (msgId: string) => SpoolMessage | null | undefined
}) {
  const route = useRoute()
  const router = useRouter()
  const thread = useThreadStore()

  /* URL -> pane: the first render, a reload, Back and Forward */
  watch(() => [route.query.thread, route.query.in] as const, () => {
    const want = targetFromQuery(route.query) as ThreadTarget | null
    if (sameTarget(want, thread.target)) return
    if (!want) return void opts.close()
    void opts.open(want, (opts.rowFor && opts.rowFor(want.rootMsgId)) || null)
  }, { immediate: true })

  /* pane -> URL */
  watch(() => thread.target, (t) => {
    const query = queryWithThread(route.query, t)
    if (sameQuery(query, route.query)) return
    void router.replace({ query })
  })

  /** A clicked row: which thread that is, then open it. */
  function openRow(msg: SpoolMessage) {
    const target = threadTargetFor(msg, { currentTaskId: opts.currentTaskId ? opts.currentTaskId() : '' }) as ThreadTarget | null
    if (!target) return
    void opts.open(target, msg)
  }

  return { openRow }
}
