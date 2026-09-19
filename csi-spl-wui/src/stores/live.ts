import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { matchesSearch, newestFirst, rootAndReplies, windowed } from '~/utils/feed.mjs'
import { catchUp, isDoor, withSessionRetry } from '~/utils/live-follow.mjs'
import type { FileRef, SpoolMessage } from '~/types/spool'

export const WINDOW = 50
const MAX_PAGES = 40

/**
 * A live feed for one task_id (005 T022, 013 reverse prepend). History from
 * view-v1 §4.4 (paged via next — §4.4 is oldest-first, spec 013 D1), then live
 * WS frames merged in. Rendered newest-first in windows; /search filters.
 * One store per pane: useLiveFeed('main') and useLiveFeed('pane').
 */
function setup(key: 'main' | 'pane') {
  const api = useSpoolApi()
  const live = useLive()
  /* the global i18n instance for the fallback error lines (a hub error keeps its own message) */
  const i18n = useNuxtApp().$i18n
  const taskId = ref<string | null>(null)
  const messages = ref<SpoolMessage[]>([])
  const error = ref<string | null>(null)
  /** view-v1 §2: the last read hit the view door (401) — pages show the door prompt. */
  const door = ref<{ detail: string } | null>(null)
  const sending = ref(false)
  const loading = ref(false)
  const search = ref('')
  const visible = ref(WINDOW)
  const liveCount = ref(0)
  /** view-v1 §4.4 desc cursor for the next older server window; null = none left. */
  const olderCursor = ref<string | null>(null)
  const loadingOlder = ref(false)
  const lastLive = ref<SpoolMessage | null>(null)

  const filtered = computed(() => newestFirst(messages.value.filter((m) => matchesSearch(m, search.value))))
  const view = computed(() => windowed(filtered.value, visible.value))
  const newestFirstRows = computed(() => view.value.rows as SpoolMessage[])
  const hasOlder = computed(() => view.value.hasOlder || Boolean(olderCursor.value))
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

  /** A read failed: the door is a prompt, anything else an error line. 404 = empty thread. */
  function fail(e: unknown, fallback: string) {
    const err = e as { status?: number, message?: string, detail?: string }
    if (isDoor(err)) {
      door.value = { detail: String(err.detail || '') }
      return
    }
    if (err.status !== 404) error.value = err.message || fallback
  }

  /** wui-live-ws §7: after a reconnect, one after=<last cursor> read, deduped by msg_id. */
  async function catchUpAfterReconnect() {
    const id = taskId.value
    if (!id) return
    try {
      const r = await catchUp(api.getThread, id, messages.value)
      if (taskId.value !== id) return
      if (r) merge(r.rows)
      else await open(id)
    } catch (e) {
      fail(e, i18n.t('feed.error.catch_up_failed'))
    }
  }

  let off: (() => void) | null = null
  let offReconnect: (() => void) | null = null
  /** `all`: also page to the oldest row (a pinned root needs it); the pane always does. */
  async function open(id: string, opts: { all?: boolean } = {}) {
    if (!id) return
    const client = live.ensure()
    if (taskId.value && taskId.value !== id && client) client.unsubscribe(taskId.value)
    if (taskId.value !== id) {
      messages.value = []
      visible.value = WINDOW
      search.value = ''
      olderCursor.value = null
    }
    taskId.value = id
    error.value = null
    door.value = null
    if (!off) {
      off = live.onMessage((m) => {
        if (m.task_id === taskId.value) merge([m as unknown as SpoolMessage], true)
      })
    }
    if (!offReconnect) offReconnect = live.onReconnected(() => { void catchUpAfterReconnect() })
    // wui-live-ws: subscribe first, then catch up over view-v1
    if (client) client.subscribe(id)
    loading.value = true
    try {
      // 013: newest window first; older windows on scroll (loadOlder)
      const data = await withSessionRetry(api, () => api.getThread(id, { order: 'desc', limit: WINDOW }))
      merge(data.messages)
      olderCursor.value = data.next
      if (opts.all || key === 'pane') await loadAll()
    } catch (e) {
      fail(e, i18n.t('feed.error.load_failed'))
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

  /**
   * Scrolling down reached the bottom: reveal the next older window. Rows
   * already held are shown first; then the next server window (before=).
   */
  async function loadOlder() {
    if (view.value.hasOlder) {
      visible.value += WINDOW
      return
    }
    if (!olderCursor.value || !taskId.value || loadingOlder.value) return
    loadingOlder.value = true
    try {
      const data = await api.getThread(taskId.value, { order: 'desc', limit: WINDOW, before: olderCursor.value })
      merge(data.messages)
      olderCursor.value = data.next
      visible.value += WINDOW
    } catch (e) {
      fail(e, i18n.t('feed.error.load_older_failed'))
      olderCursor.value = null
    } finally {
      loadingOlder.value = false
    }
  }

  /** The pinned root of a long thread needs the oldest row: page to the end. */
  async function loadAll() {
    for (let i = 0; i < MAX_PAGES && olderCursor.value; i++) await loadOlder()
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
      error.value = e instanceof Error ? e.message : i18n.t('feed.error.send_failed')
    } finally {
      sending.value = false
    }
  }

  return {
    taskId, messages, newestFirst: newestFirstRows, hasOlder, thread, error, door, sending, loading,
    search, liveCount, lastLive, open, close, send, loadOlder, loadAll, setSearch, catchUpAfterReconnect,
  }
}

export function useLiveFeed(key: 'main' | 'pane' = 'main') {
  return defineStore(`live-${key}`, () => setup(key))()
}

/** 005 name kept for callers of the main feed. */
export const useLiveStore = () => useLiveFeed('main')
