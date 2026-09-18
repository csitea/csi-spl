import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import type { FileRef, SpoolMessage } from '~/types/spool'

/**
 * Live thread / lobby state: history from view-v1 §4.4 (REST, survives reload),
 * then live frames from the WUI socket appended without reload. Rendered
 * newest-first (SPEC-spool-wui-layout: reverse prepend stream).
 */
export const useLiveStore = defineStore('live', () => {
  const api = useSpoolApi()
  const live = useLive()
  const taskId = ref<string | null>(null)
  const messages = ref<SpoolMessage[]>([])
  const error = ref<string | null>(null)
  const sending = ref(false)

  const newestFirst = computed(() => messages.value.slice().sort((a, b) =>
    String(b.received_at || b.ts || '').localeCompare(String(a.received_at || a.ts || ''))))

  function merge(rows: SpoolMessage[]) {
    const seen = new Set(messages.value.map((m) => m.msg_id))
    const add = rows.filter((m) => m.msg_id && !seen.has(m.msg_id))
    if (add.length) messages.value = [...messages.value, ...add]
  }

  let off: (() => void) | null = null
  async function open(id: string) {
    if (!id) return
    const client = live.ensure()
    if (taskId.value && taskId.value !== id && client) client.unsubscribe(taskId.value)
    if (taskId.value !== id) messages.value = []
    taskId.value = id
    error.value = null
    if (!off) {
      off = live.onMessage((m) => {
        if (m.task_id === taskId.value) merge([m as unknown as SpoolMessage])
      })
    }
    if (client) client.subscribe(id)
    try {
      const data = await api.getThread(id)
      merge(data.messages)
    } catch (e) {
      const err = e as { status?: number, message?: string }
      // a brand-new lobby has no stored messages yet: 404 is an empty history
      if (err.status !== 404) error.value = err.message || 'load failed'
    }
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
      const client = live.ensure()
      if (client) {
        await client.send({ task_id: taskId.value, kind: 'note', body, files: refs })
      } else {
        // mock tenant: local echo
        merge([{
          v: 1, msg_id: crypto.randomUUID(), task_id: taskId.value, ts: new Date().toISOString(),
          from: live.identity.value, to: 'ALL-0', kind: 'note', body, files: refs, from_box: 'box-wui',
        } as SpoolMessage])
      }
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'send failed'
    } finally {
      sending.value = false
    }
  }

  return { taskId, messages, newestFirst, error, sending, open, send }
})
