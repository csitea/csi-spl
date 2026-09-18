import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
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

  function fail(e: unknown) {
    const err = e as { status?: number, token?: string, message?: string }
    needsToken.value = err.status === 401
    if (err.status === 404 && err.token === 'unknown_tenant') error.value = 'Unknown tenant for this host.'
    else if (err.status === 404) error.value = 'Not found.'
    else if (err.status === 401) error.value = 'A view token is required.'
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

  return { threads, next, taskId, messages, loading, error, needsToken, loadThreads, loadMore, openThread, refreshThread }
})
