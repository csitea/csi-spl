import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { matchesSearch, newestFirst, rootAndReplies, windowed } from '~/utils/feed.mjs'
import type { FileRef, SpoolMessage } from '~/types/spool'

export const WINDOW = 50
const MAX_PAGES = 40

/**
 * A live feed for one task_id (005 T022, 013 reverse prepend). History from
 * view-v1 §4.4 (paged via next — §4.4 is oldest-first, spec 013 D1), then live
 * WS frames merged in. Rendered newest-first in windows; /search filters.
 * One store per pane: useLiveFeed('main') and useLiveFeed('pane').
 */
function setup() {
  const api = useSpoolApi()
  const live = useLive()
  const taskId = ref<string | null>(null)
  const messages = ref<SpoolMessage[]>([])
  const error = ref<string | null>(null)
  const sending = ref(false)
  const loading = ref(false)
  const search = ref('')
  const visible = ref(WINDOW)
  const liveCount = ref(0)
  const lastLive = ref<SpoolMessage | null>(null)

  const filtered = computed(() => newestFirst(messages.value.filter((m) => matchesSearch(m, search.value))))
  const view = computed(() => windowed(filtered.value, visible.value))
  const newestFirstRows = computed(() => view.value.rows as SpoolMessage[])
  const hasOlder = computed(() => view.value.hasOlder)
  const thread = computed(() => rootAndReplies(messages.value.filter((m) => matchesSearch(m, search.value))))

  function merge(rows: SpoolMessage[], fromLive = false) {
    const seen = new Set(messages.value.map((m) => m.msg_id))
    const add = rows.filter((m) => m && m.msg_id && !seen.has(m.msg_id))
    if (!add.length) return
    messages.value = [...messages.value, ...add]
    if (fromLive) {
      liveCount.value += add.length
      lastLive.value = add[add.length - 1]
    }
  }

  let off: (() => void) | null = null
  async function open(id: string) {
    if (!id) return
    const client = live.ensure()
    if (taskId.value && taskId.value !== id && client) client.unsubscribe(taskId.value)
    if (taskId.value !== id) {
      messages.value = []
      visible.value = WINDOW
      search.value = ''
    }
    taskId.value = id
    error.value = null
    if (!off) {
      off = live.onMessage((m) => {
        if (m.task_id === taskId.value) merge([m as unknown as SpoolMessage], true)
      })
    }
    // wui-live-ws: subscribe first, then catch up over view-v1
    if (client) client.subscribe(id)
    loading.value = true
    try {
      let after: string | undefined
      for (let page = 0; page < MAX_PAGES; page++) {
        const data = await api.getThread(id, after ? { after } : undefined)
        merge(data.messages)
        if (!data.next) break
        after = data.next
      }
    } catch (e) {
      const err = e as { status?: number, message?: string }
      if (err.status !== 404) error.value = err.message || 'load failed'
    } finally {
      loading.value = false
    }
  }

  function close() {
    const client = live.ensure()
    if (taskId.value && client) client.unsubscribe(taskId.value)
    taskId.value = null
    messages.value = []
  }

  /** Scrolling down reached the bottom: reveal the next older window. */
  function loadOlder() {
    if (hasOlder.value) visible.value += WINDOW
  }

  function setSearch(q: string) {
    search.value = q
    visible.value = WINDOW
  }

  async function send(body: string, files: File[] = []) {
    if (!taskId.value) return
    sending.value = true
    error.value = null
    try {
      const refs: FileRef[] = []
      for (const f of files) {
        const up = await api.uploadFile(f, await live.freshUploadToken()) as { file_id: string, sha256: string, bytes: number }
        refs.push({ mode: 'blob', kind: 'file', file_id: up.file_id, sha256: up.sha256, bytes: up.bytes, name: f.name })
      }
      const m = body.match(/^@([A-Z]{2,4}-\d+)\b\s*([\s\S]*)$/)
      const kind = m ? 'task' : 'note'
      const to = m ? m[1] : undefined
      const text = m ? m[2] : body
      const client = live.ensure()
      if (client) {
        await client.send({ task_id: taskId.value, kind, body: text, files: refs, to })
      } else {
        merge([{
          v: 1, msg_id: crypto.randomUUID(), task_id: taskId.value, ts: new Date().toISOString(),
          from: live.identity.value, to: to || 'ALL-0', kind, body: text, files: refs, from_box: 'box-wui',
        } as SpoolMessage], true)
      }
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'send failed'
    } finally {
      sending.value = false
    }
  }

  return {
    taskId, messages, newestFirst: newestFirstRows, hasOlder, thread, error, sending, loading,
    search, liveCount, lastLive, open, close, send, loadOlder, setSearch,
  }
}

export function useLiveFeed(key: 'main' | 'pane' = 'main') {
  return defineStore(`live-${key}`, setup)()
}

/** 005 name kept for callers of the main feed. */
export const useLiveStore = () => useLiveFeed('main')
