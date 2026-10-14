import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { isDoor, withSessionRetry } from '~/utils/live-follow.mjs'
import { bumpTopic, mergeTopicPage } from '~/utils/topic-list.mjs'
import { archiveStamp, withoutTopics } from '~/utils/topic-archive.mjs'
import { topicsWithKind } from '~/utils/topic-kind.mjs'
import { useLive } from '~/composables/useLive'
import type { SpoolMessage, TopicRow } from '~/types/spool'

type Failure = { key: string, params?: Record<string, string>, raw?: string }
type SpoolApi = ReturnType<typeof useSpoolApi>

/* The viewer's state: the refs the store hands out as they are. */
function viewerState() {
  /* SPL-1219: both row lists are READ-ONLY to the UI and only ever replaced
     wholesale (never mutated in place - see every topics.value/messages.value
     write below), so shallowRef skips the deep reactive proxy over every row.
     topics is re-derived on EVERY live message (bumpTopic), so this is on the
     hot path; the same call SPL-5086 made for the live/channel stores. */
  const topics = shallowRef<TopicRow[]>([])
  const next = ref<string | null>(null)
  const taskId = ref<string | null>(null)
  const messages = shallowRef<SpoolMessage[]>([])
  const loading = ref(false)
  /*
   * spec 021: the failure as a catalogue key (or the client's raw technical
   * message); `error` renders it in the ACTIVE locale, so a language switch
   * re-renders it. The global composer's t() is reactive on the locale.
   */
  const failure = ref<Failure | null>(null)
  const needsToken = ref(false)
  /** The hub's 401 detail: it names the ways in (view-v1 §2), ViewTokenForm reads it. */
  const doorDetail = ref('')
  /*
   * HUM-10 (t1 9e969f63): a kind set on ANY card - the row badge, a card in
   * the open topic (the opener included), the keyboard - moves the row's
   * kind counts at once, so clearing the last blocker drops the row's
   * blocker badge with no reload. kindSet remembers the new kind by msg_id
   * for the opener a list row holds.
   */
  const kindSet = shallowRef<Record<string, string>>({})
  return { topics, next, taskId, messages, loading, failure, needsToken, doorDetail, kindSet }
}

type ViewerState = ReturnType<typeof viewerState>

/* A load error that is not the door, as the catalogue key the panel shows. */
function failureOf(err: { status?: number, token?: string, message?: string }): Failure {
  /* specs/026: a session in several tenants with none active - sign in with ?tenant=<id> */
  if (err.token === 'no_tenant' || (err.status === 409 && err.token === 'tenant_required')) return { key: 'viewer.error.no_tenant', params: { query: '?tenant=<id>' } }
  if (err.token === 'api_host') return { key: 'viewer.error.api_host', params: { host: '<tenant>.<domain>', env_var: 'NUXT_PUBLIC_API_BASE', tenant: '{tenant}' } }
  if (err.token === 'no_base' || err.token === 'bad_base') return { key: 'viewer.error.no_base' }
  if (err.status === 404 && err.token === 'unknown_tenant') return { key: 'viewer.error.unknown_tenant' }
  if (err.status === 404) return { key: 'viewer.error.not_found' }
  /* the client's own message is technical text (like the diagnostics panel's), kept as is */
  return err.message ? { key: '', raw: err.message } : { key: 'viewer.error.load_failed' }
}

function failAction(s: ViewerState) {
  return function fail(e: unknown) {
    const err = e as { status?: number, token?: string, message?: string, detail?: string }
    s.needsToken.value = isDoor(err)
    s.doorDetail.value = String(err.detail || '')
    s.failure.value = s.needsToken.value ? null : failureOf(err)
  }
}

function listActions(s: ViewerState, api: SpoolApi, fail: (e: unknown) => void) {
  async function loadTopics() {
    s.loading.value = true
    s.failure.value = null
    try {
      /* 010 FR-009: a member-session door rides the sign-in cookie */
      const data = await withSessionRetry(api, () => api.listTopics({ limit: 50 }))
      s.topics.value = data.topics
      s.next.value = data.next
      s.needsToken.value = false
    } catch (e) {
      fail(e)
    } finally {
      s.loading.value = false
    }
  }

  async function loadMore() {
    if (!s.next.value) return
    try {
      const data = await api.listTopics({ limit: 50, before: s.next.value })
      s.topics.value = [...s.topics.value, ...(data.topics)]
      s.next.value = data.next
    } catch (e) {
      fail(e)
    }
  }

  async function catchUp() {
    try {
      const data = await api.listTopics({ limit: 50 })
      s.topics.value = mergeTopicPage(s.topics.value, data.topics) as TopicRow[]
    } catch (e) {
      fail(e)
    }
  }

  async function dropIfArchived(id: string) {
    if (!id) return
    try {
      if (archiveStamp(await api.getTopic(id, { limit: 1 }))) dropTopics([id])
    } catch {
      /* the row stays; the next catch-up re-reads the list */
    }
  }

  /** SPL-986: an archived or deleted topic leaves the list (specs/041 §3.5). */
  function dropTopics(taskIds: string[]) {
    if (!taskIds.length) return
    s.topics.value = withoutTopics(s.topics.value, taskIds)
  }

  function setKind(taskId: string, msgId: string, from: string, to: string) {
    const { topics, kindSet } = s
    topics.value = topicsWithKind(topics.value, taskId, from, to)
    if (msgId && to) kindSet.value = { ...kindSet.value, [msgId]: to }
  }
  return { loadTopics, loadMore, catchUp, dropIfArchived, dropTopics, setKind }
}

/*
 * 013 US7 FR-011: the topic list is live — the socket follows the whole
 * tenant (wui-live-ws v0.5 `all`), a pushed message moves its row to the
 * top; a reconnect re-reads the first page and merges it by task_id.
 */
function followActions(s: ViewerState, api: SpoolApi, list: { catchUp: () => Promise<void>, dropIfArchived: (id: string) => Promise<void> }) {
  let offMessage: (() => unknown) | null = null
  let offReconnect: (() => unknown) | null = null
  function follow() {
    if (api.mock || !import.meta.client || offMessage) return
    const live = useLive()
    const client = live.ensure()
    if (!client) return
    client.subscribeAll()
    offMessage = live.onMessage((m) => {
      const before = s.topics.value
      s.topics.value = bumpTopic(before, m) as TopicRow[]
      /* t1 8fb802cd: a message in a topic the list does not hold starts a
         row - and an agent still writing into an ARCHIVED topic put that
         topic back among the live ones. One read of the new row's topic
         answers its archive stamp; an archived one leaves again. */
      if (s.topics.value.length > before.length) void list.dropIfArchived(String(m.task_id || ''))
    })
    offReconnect = live.onReconnected(() => { void list.catchUp() })
  }
  function unfollow() {
    if (offMessage) offMessage()
    if (offReconnect) offReconnect()
    offMessage = offReconnect = null
    if (api.mock || !import.meta.client) return
    const client = useLive().ensure()
    if (client) client.unsubscribeAll()
  }
  return { follow, unfollow }
}

function topicActions(s: ViewerState, api: SpoolApi, fail: (e: unknown) => void) {
  async function openTopic(id: string) {
    if (s.taskId.value !== id) s.messages.value = []
    s.taskId.value = id
    await refreshTopic()
  }

  /** view-v1 §4.4: the first read is the whole topic; later polls pass the last cursor as after= and append. */
  async function refreshTopic() {
    if (!s.taskId.value) return
    const last = s.messages.value[s.messages.value.length - 1]
    const after = last && last.cursor ? last.cursor : undefined
    s.loading.value = s.messages.value.length === 0
    s.failure.value = null
    try {
      const data = await api.getTopic(s.taskId.value, after ? { after } : undefined)
      if (after) {
        const seen = new Set(s.messages.value.map((m) => m.msg_id))
        s.messages.value = [...s.messages.value, ...data.messages.filter((m) => !seen.has(m.msg_id))]
      } else {
        s.messages.value = data.messages
      }
      s.needsToken.value = false
    } catch (e) {
      fail(e)
    } finally {
      s.loading.value = false
    }
  }
  return { openTopic, refreshTopic }
}

/** Read-only topic viewer (spec 005 US1, US2, US4) over 003 view-v1 §4.3 / §4.4. */
export const useViewerStore = defineStore('viewer', () => {
  const api = useSpoolApi()
  const s = viewerState()
  const { topics, next, taskId, messages, loading, needsToken, doorDetail, kindSet } = s
  const nuxtApp = useNuxtApp()
  const error = computed<string | null>(() => {
    const f = s.failure.value
    if (!f) return null
    return f.raw || nuxtApp.$i18n.t(f.key, f.params || {})
  })
  const fail = failAction(s)
  const { loadTopics, loadMore, catchUp, dropIfArchived, dropTopics, setKind } = listActions(s, api, fail)
  const { follow, unfollow } = followActions(s, api, { catchUp, dropIfArchived })
  const { openTopic, refreshTopic } = topicActions(s, api, fail)

  return { topics, next, taskId, messages, loading, error, needsToken, doorDetail, loadTopics, loadMore, dropTopics, kindSet, setKind, openTopic, refreshTopic, follow, unfollow, catchUp }
})
