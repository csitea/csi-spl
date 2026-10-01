import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { dropFlow, mergeFlow } from '~/utils/flow-entries.mjs'
import type { FlowEntry } from '~/utils/flow-entries.mjs'
import type { SpoolMessage } from '~/types/spool'

/** Topics read on the first load, and each one's newest messages inlined. */
const FLOW_TOPICS = 40
const FLOW_PER_TOPIC = 3

/**
 * Flow (topic 635f8072): the stream of short message entries in the left
 * panel, newest first. The first read is the newest topics with their last
 * few messages inlined (one request); live frames then add to the top, an
 * edit replaces its entry and a delete drops it. The selection lives here
 * too, so the list keeps it while the middle pane changes route.
 */
export const useFlowStore = defineStore('flow', () => {
  const api = useSpoolApi()
  const entries = shallowRef<FlowEntry[]>([])
  const loading = ref(false)
  const loaded = ref(false)
  const error = ref('')
  /** The selected entry (keyboard + the last one opened). */
  const activeKey = ref('')
  /** Entries opened from the Flow in this tab: their unread dot goes. */
  const opened = shallowRef<Set<string>>(new Set())

  function self() {
    const session = useSessionStore()
    const roster = useRosterStore()
    return String(session.claims?.hum || useLive().identity.value || roster.self?.id || '')
  }

  function add(rows: unknown[]) {
    const next = mergeFlow(entries.value, rows, self()) as FlowEntry[]
    if (next !== entries.value) entries.value = next
  }

  async function load() {
    if (loading.value) return
    loading.value = true
    error.value = ''
    try {
      if (api.mock) {
        /* the mock has no inlined pages: its whole feed is held in memory */
        const r = await api.listMessages({ limit: 200 })
        add(r.messages)
      } else {
        const r = await withSessionRetry(api, () => api.listTopics({ limit: FLOW_TOPICS, perTopic: FLOW_PER_TOPIC }))
        const rows: SpoolMessage[] = []
        for (const t of r.topics as Array<{ inline?: { messages: SpoolMessage[] } }>) {
          if (t.inline) rows.push(...t.inline.messages)
        }
        add(rows)
      }
      loaded.value = true
    } catch (e) {
      error.value = String((e as Error)?.message || e)
    } finally {
      loading.value = false
    }
  }

  let following = false
  /** Live frames: the tab-wide `all` follow (plugins/spool-live.client.ts) feeds them. */
  function follow() {
    if (following || !import.meta.client) return
    following = true
    const live = useLive()
    live.onMessage((m) => add([m]))
    live.onEdited((m) => add([m]))
    live.onDeleted((m) => { entries.value = dropFlow(entries.value, String(m.msg_id || '')) as FlowEntry[] })
    live.onReconnected(() => { void load() })
  }

  /** Open the Flow: the first time reads it, later only the mock re-reads (it has no socket). */
  function ensure() {
    follow()
    if (!loaded.value || api.mock) void load()
  }

  function select(key: string) {
    activeKey.value = key
  }

  function markOpened(key: string) {
    if (!key || opened.value.has(key)) return
    opened.value = new Set([...opened.value, key])
  }

  /** A message deleted here (not a live frame) leaves the stream too. */
  function drop(msgId: string) {
    entries.value = dropFlow(entries.value, msgId) as FlowEntry[]
  }

  return { entries, loading, loaded, error, activeKey, opened, ensure, load, select, markOpened, drop, self }
})
