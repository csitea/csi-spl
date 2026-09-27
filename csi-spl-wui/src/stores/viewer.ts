import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { isDoor, withSessionRetry } from '~/utils/live-follow.mjs'
import { bumpTopic, mergeTopicPage } from '~/utils/topic-list.mjs'
import { withoutTopics } from '~/utils/topic-archive.mjs'
import { useLive } from '~/composables/useLive'
import type { SpoolMessage, TopicRow } from '~/types/spool'

/** Read-only topic viewer (spec 005 US1, US2, US4) over 003 view-v1 §4.3 / §4.4. */
export const useViewerStore = defineStore('viewer', () => {
  const api = useSpoolApi()
  const topics = ref<TopicRow[]>([])
  const next = ref<string | null>(null)
  const taskId = ref<string | null>(null)
  const messages = ref<SpoolMessage[]>([])
  const loading = ref(false)
  /*
   * spec 021: the failure as a catalogue key (or the client's raw technical
   * message); `error` renders it in the ACTIVE locale, so a language switch
   * re-renders it. The global composer's t() is reactive on the locale.
   */
  const nuxtApp = useNuxtApp()
  const failure = ref<{ key: string, params?: Record<string, string>, raw?: string } | null>(null)
  const error = computed<string | null>(() => {
    const f = failure.value
    if (!f) return null
    return f.raw || nuxtApp.$i18n.t(f.key, f.params || {})
  })
  const needsToken = ref(false)
  /** The hub's 401 detail: it names the ways in (view-v1 §2), ViewTokenForm reads it. */
  const doorDetail = ref('')

  function fail(e: unknown) {
    const err = e as { status?: number, token?: string, message?: string, detail?: string }
    needsToken.value = isDoor(err)
    doorDetail.value = String(err.detail || '')
    if (needsToken.value) {
      failure.value = null
      return
    }
    /* specs/026: a session in several tenants with none active - sign in with ?tenant=<id> */
    if (err.token === 'no_tenant' || (err.status === 409 && err.token === 'tenant_required')) failure.value = { key: 'viewer.error.no_tenant', params: { query: '?tenant=<id>' } }
    else if (err.token === 'api_host') failure.value = { key: 'viewer.error.api_host', params: { host: '<tenant>.<domain>', env_var: 'NUXT_PUBLIC_API_BASE', tenant: '{tenant}' } }
    else if (err.token === 'no_base' || err.token === 'bad_base') failure.value = { key: 'viewer.error.no_base' }
    else if (err.status === 404 && err.token === 'unknown_tenant') failure.value = { key: 'viewer.error.unknown_tenant' }
    else if (err.status === 404) failure.value = { key: 'viewer.error.not_found' }
    /* the client's own message is technical text (like the diagnostics panel's), kept as is */
    else failure.value = err.message ? { key: '', raw: err.message } : { key: 'viewer.error.load_failed' }
  }

  async function loadTopics() {
    loading.value = true
    failure.value = null
    try {
      /* 010 FR-009: a member-session door rides the sign-in cookie */
      const data = await withSessionRetry(api, () => api.listTopics({ limit: 50 }))
      topics.value = data.topics
      next.value = data.next
      needsToken.value = false
    } catch (e) {
      fail(e)
    } finally {
      loading.value = false
    }
  }

  async function loadMore() {
    if (!next.value) return
    try {
      const data = await api.listTopics({ limit: 50, before: next.value })
      topics.value = [...topics.value, ...(data.topics)]
      next.value = data.next
    } catch (e) {
      fail(e)
    }
  }

  /*
   * 013 US7 FR-011: the topic list is live — the socket follows the whole
   * tenant (wui-live-ws v0.5 `all`), a pushed message moves its row to the
   * top; a reconnect re-reads the first page and merges it by task_id.
   */
  let offMessage: (() => unknown) | null = null
  let offReconnect: (() => unknown) | null = null
  function follow() {
    if (api.mock || !import.meta.client || offMessage) return
    const live = useLive()
    const client = live.ensure()
    if (!client) return
    client.subscribeAll()
    offMessage = live.onMessage((m) => { topics.value = bumpTopic(topics.value, m) as TopicRow[] })
    offReconnect = live.onReconnected(() => { void catchUp() })
  }
  function unfollow() {
    if (offMessage) offMessage()
    if (offReconnect) offReconnect()
    offMessage = offReconnect = null
    if (api.mock || !import.meta.client) return
    const client = useLive().ensure()
    if (client) client.unsubscribeAll()
  }
  async function catchUp() {
    try {
      const data = await api.listTopics({ limit: 50 })
      topics.value = mergeTopicPage(topics.value, data.topics) as TopicRow[]
    } catch (e) {
      fail(e)
    }
  }

  /** SPL-986: an archived or deleted topic leaves the list (specs/041 §3.5). */
  function dropTopics(taskIds: string[]) {
    if (!taskIds.length) return
    topics.value = withoutTopics(topics.value, taskIds)
  }

  async function openTopic(id: string) {
    if (taskId.value !== id) messages.value = []
    taskId.value = id
    await refreshTopic()
  }

  /** view-v1 §4.4: the first read is the whole topic; later polls pass the last cursor as after= and append. */
  async function refreshTopic() {
    if (!taskId.value) return
    const last = messages.value[messages.value.length - 1]
    const after = last && last.cursor ? last.cursor : undefined
    loading.value = messages.value.length === 0
    failure.value = null
    try {
      const data = await api.getTopic(taskId.value, after ? { after } : undefined)
      if (after) {
        const seen = new Set(messages.value.map((m) => m.msg_id))
        messages.value = [...messages.value, ...data.messages.filter((m) => !seen.has(m.msg_id))]
      } else {
        messages.value = data.messages
      }
      needsToken.value = false
    } catch (e) {
      fail(e)
    } finally {
      loading.value = false
    }
  }

  return { topics, next, taskId, messages, loading, error, needsToken, doorDetail, loadTopics, loadMore, dropTopics, openTopic, refreshTopic, follow, unfollow, catchUp }
})
