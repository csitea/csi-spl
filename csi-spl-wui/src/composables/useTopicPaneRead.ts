/**
 * TopicPane's topic read and paging (r18-05): the first page of the open
 * topic, Load more, the catch-up after a reconnect, the heading's first
 * message and the page-back toward a #<msg_id> hash. The SFC hands in its
 * topic store, the spool api and t(); the refs come back for its template
 * and the rest of its script. Called in the pane's setup, so the watches
 * stop when it unmounts.
 *
 * Live: a channel / DM feed row is a topic root only (view-v1 §4.3), so the
 * replies come from GET /v1/view/topics/{task_id} and then the WS frames.
 * Messages prepend at the top: the newest is the first row, and a message
 * that just arrived sorts above the ones already there. The reply box is
 * the top Omnibox, not a second field in this pane.
 * The newest WINDOW (30) replies come first (order=desc); Load more reads the
 * next 30 older ones with before=<next>, so a long topic is never cut off.
 */
import { WINDOW } from '~/stores/channel'
import type { useTopicStore } from '~/stores/topic'
import type { useSpoolApi } from '~/composables/useSpoolApi'
import { mergeById } from '~/utils/feed.mjs'
import { archiveStamp } from '~/utils/topic-archive.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import type { SpoolMessage } from '~/types/spool'

export type TopicPaneReadOptions = {
  topic: ReturnType<typeof useTopicStore>
  api: ReturnType<typeof useSpoolApi>
  t: (key: string) => string
}

/** The pane's read state: the refs the template and the loaders below share. */
function readState() {
  const liveRows = ref<SpoolMessage[]>([])
  const loadError = ref('')
  /* SPL-1839: the rejection behind loadError, for the Debug pane line; Try again bumps the tick */
  const loadErr = ref<unknown>(null)
  const retryTick = ref(0)
  const loading = ref(false)
  const search = ref('')
  const lastLive = ref<SpoolMessage | null>(null)
  const olderCursor = ref<string | null>(null)
  const loadingOlder = ref(false)
  /* The topic's first message, for the heading, when the newest page does not reach it. */
  const oldestRow = ref<SpoolMessage | null>(null)
  /* t1 8fb802cd: the open topic's archive stamp ('' = live), from its first read */
  const archivedAt = ref('')
  /* the mock pane shows the channel store's rows; older replies past them
     are read with Load more as live does (a jump to an old reply needs them) */
  const mockHead = shallowRef<SpoolMessage[]>([])
  const hasOlder = computed(() => Boolean(olderCursor.value))
  return { liveRows, loadError, loadErr, retryTick, loading, search, lastLive, olderCursor, loadingOlder, oldestRow, archivedAt, mockHead, hasOlder }
}
type ReadState = ReturnType<typeof readState>
type Pager = { loadOlder: () => Promise<void>, loadOldestRow: (id: string) => Promise<void> }

function topicCatchUp({ topic, api, t }: TopicPaneReadOptions, { liveRows, loadError, loadErr, archivedAt }: ReadState) {
  /** 013 US7 FR-015: after a reconnect, re-read the topic and merge it by msg_id. */
  async function catchUp() {
    const id = topic.parentTaskId
    if (api.mock || !topic.open || !id) return
    try {
      const data = await withSessionRetry(api, () => api.getTopic(id, { order: 'desc', limit: 50 })) as { messages?: SpoolMessage[] }
      if (topic.parentTaskId === id) {
        liveRows.value = mergeById(liveRows.value, data.messages || []).rows as SpoolMessage[]
        archivedAt.value = archiveStamp(data)
      }
    } catch (e) {
      loadErr.value = e
      loadError.value = t('topic.load_failed')
    }
  }
  return catchUp
}

/** Each open (and Try again) reads the first page; a #<msg_id> hash pages back to its reply. */
function watchTopicOpen({ topic, api, t }: TopicPaneReadOptions, s: ReadState, { loadOlder, loadOldestRow }: Pager) {
  const { liveRows, loadError, loadErr, retryTick, loading, search, lastLive, olderCursor, oldestRow, archivedAt, mockHead } = s
  /* CLE-77909: a link to a reply (/m/<id>, #<msg_id>) older than the newest
     WINDOW: read older pages until it is held, so the feed can scroll to it and
     mark it. At most HASH_PAGES pages; past that the reader pages by hand. */
  const HASH_PAGES = 10
  const route = useRoute()
  async function reachHash() {
    const id = topic.parentTaskId
    const want = String(route.hash || '').replace(/^#/, '')
    if (api.mock || !id || !want) return
    for (let i = 0; i < HASH_PAGES && olderCursor.value && topic.parentTaskId === id; i++) {
      if (liveRows.value.some((r) => String(r.msg_id) === want)) return
      await loadOlder()
    }
  }
  watch(() => route.hash, () => { if (!loading.value) void reachHash() })

  watch(() => [topic.open, topic.parentTaskId, retryTick.value] as const, async ([open, id]) => {
    liveRows.value = []
    loadError.value = ''
    search.value = ''
    lastLive.value = null
    olderCursor.value = null
    oldestRow.value = null
    archivedAt.value = ''
    mockHead.value = []
    if (!open || !id) return
    if (api.mock) {
      /* t1 404cd808: the mock pane shows no read, but marks an archived topic as the live one does */
      void withSessionRetry(api, () => api.getTopic(id, { order: 'desc', limit: WINDOW })).then((d) => {
        if (topic.parentTaskId !== id) return
        archivedAt.value = archiveStamp(d)
        mockHead.value = (d.messages || []) as SpoolMessage[]
        olderCursor.value = d.next || null
      }).catch((e) => {
        /* no answer: the pane shows the held rows, unmarked, without Load more;
           SPL-1839: the e2e fault hook (spool.mock.read-fault) says it */
        if ((e as { mockFault?: boolean })?.mockFault) {
          loadErr.value = e
          loadError.value = t('topic.load_failed')
        }
      })

      return
    }
    loading.value = true
    try {
      const data = await withSessionRetry(api, () => api.getTopic(id, { order: 'desc', limit: WINDOW })) as { messages?: SpoolMessage[], next?: string | null }
      if (topic.parentTaskId !== id) return
      liveRows.value = data.messages || []
      olderCursor.value = data.next || null
      archivedAt.value = archiveStamp(data)
      if (olderCursor.value && !topic.rootMsg) void loadOldestRow(id)
    } catch (e) {
      loadErr.value = e
      loadError.value = t('topic.load_failed')
    } finally {
      loading.value = false
    }
    void reachHash()
  }, { immediate: true })
}

function topicPager({ topic, api, t }: TopicPaneReadOptions, { liveRows, loadError, loadErr, olderCursor, loadingOlder, oldestRow, mockHead }: ReadState): Pager {
  /** Load more: the next WINDOW older replies (before=<next>), merged by msg_id. */
  async function loadOlder() {
    const id = topic.parentTaskId
    if (!id || !olderCursor.value || loadingOlder.value) return
    loadingOlder.value = true
    try {
      const data = await withSessionRetry(api, () => api.getTopic(id, { order: 'desc', limit: WINDOW, before: olderCursor.value || undefined })) as { messages?: SpoolMessage[], next?: string | null }
      if (topic.parentTaskId !== id) return
      liveRows.value = mergeById([...liveRows.value, ...mockHead.value], data.messages || []).rows as SpoolMessage[]
      mockHead.value = []

      olderCursor.value = data.next || null
    } catch (e) {
      loadErr.value = e
      loadError.value = t('feed.error.load_older_failed')
      olderCursor.value = null
    } finally {
      loadingOlder.value = false
    }
  }

  async function loadOldestRow(id: string) {
    try {
      const data = await withSessionRetry(api, () => api.getTopic(id, { limit: 1 })) as { messages?: SpoolMessage[] }
      if (topic.parentTaskId === id) oldestRow.value = (data.messages || [])[0] || null
    } catch {
      /* the heading falls back to the oldest row held */
    }
  }
  return { loadOlder, loadOldestRow }
}

export function useTopicPaneRead(o: TopicPaneReadOptions) {
  const s = readState()
  const { loadOlder, loadOldestRow } = topicPager(o, s)
  const catchUp = topicCatchUp(o, s)
  watchTopicOpen(o, s, { loadOlder, loadOldestRow })
  const { liveRows, loadError, loadErr, retryTick, loading, search, lastLive, loadingOlder, oldestRow, archivedAt, hasOlder } = s
  return { liveRows, loadError, loadErr, retryTick, loading, search, lastLive, loadingOlder, oldestRow, archivedAt, hasOlder, catchUp, loadOlder }
}
