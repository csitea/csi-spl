import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { isDoor } from '~/utils/live-follow.mjs'
import type { SpoolMessage, ThreadRow } from '~/types/spool'

/** Read-only thread viewer (spec 005 US1, US2, US4) over 003 view-v1 §4.3 / §4.4. */
export const useViewerStore = defineStore('viewer', () => {
  const api = useSpoolApi()
  const threads = ref<ThreadRow[]>([])
  const next = ref<string | null>(null)
  const taskId = ref<string | null>(null)
  const messages = ref<SpoolMessage[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)
  const needsToken = ref(false)
  /** The hub's 401 detail: it names the ways in (view-v1 §2), ViewTokenForm reads it. */
  const doorDetail = ref('')

  function fail(e: unknown) {
    const err = e as { status?: number, token?: string, message?: string, detail?: string }
    needsToken.value = isDoor(err)
    doorDetail.value = String(err.detail || '')
    if (needsToken.value) {
      error.value = null
      return
    }
    if (err.token === 'no_tenant') error.value = 'No tenant selected — open the viewer with ?tenant=<id>.'
    else if (err.token === 'api_host') error.value = 'The hub URL is the API host; tenant reads need <tenant>.<domain> (NUXT_PUBLIC_API_BASE with {tenant}).'
    else if (err.token === 'no_base' || err.token === 'bad_base') error.value = 'NUXT_PUBLIC_API_BASE is missing or invalid.'
    else if (err.status === 404 && err.token === 'unknown_tenant') error.value = 'Unknown tenant for this host.'
    else if (err.status === 404) error.value = 'Not found.'
    else error.value = err.message || 'load failed'
  }

  async function loadThreads() {
    loading.value = true
    error.value = null
    try {
      const data = await api.listThreads({ limit: 50 })
      threads.value = data.threads
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
      const data = await api.listThreads({ limit: 50, before: next.value })
      threads.value = [...threads.value, ...(data.threads)]
      next.value = data.next
    } catch (e) {
      fail(e)
    }
  }

  async function openThread(id: string) {
    if (taskId.value !== id) messages.value = []
    taskId.value = id
    await refreshThread()
  }

  /** view-v1 §4.4: the first read is the whole thread; later polls pass the last cursor as after= and append. */
  async function refreshThread() {
    if (!taskId.value) return
    const last = messages.value[messages.value.length - 1]
    const after = last && last.cursor ? last.cursor : undefined
    loading.value = messages.value.length === 0
    error.value = null
    try {
      const data = await api.getThread(taskId.value, after ? { after } : undefined)
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

  return { threads, next, taskId, messages, loading, error, needsToken, doorDetail, loadThreads, loadMore, openThread, refreshThread }
})
