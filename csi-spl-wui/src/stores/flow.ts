import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { FLOW_PAGE, dropFlow, flowWindow, mergeFlow } from '~/utils/flow-entries.mjs'
import type { FlowEntry } from '~/utils/flow-entries.mjs'
import type { SpoolMessage } from '~/types/spool'

/**
 * Topics one read asks for, and each one's newest messages inlined: enough
 * for a page of FLOW_PAGE entries (owner 73c9704c: "use the last 30 entries
 * ... to be quick and nimble"). It was 40 topics on the first load.
 */
const FLOW_TOPICS = 12
const FLOW_PER_TOPIC = 3
/** Topic pages one fill may read before it shows what it has. */
const FLOW_FILL_PAGES = 4

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
  /** Entries shown: a page, and a page more per Load more. */
  const shown = ref(FLOW_PAGE)
  /** The hub's cursor to the next older topic page ('' = none left). */
  const next = ref('')
  /** The oldest read topic's last activity, while an older page is unread. */
  const boundary = ref('')
  const loadingMore = ref(false)
  const view = computed(() => flowWindow(entries.value, shown.value, next.value ? boundary.value : ''))
  /** What the panel lists: the newest `shown` entries the read pages vouch for. */
  const visible = computed(() => view.value.entries as FlowEntry[])
  const hasMore = computed(() => view.value.more)

  function self() {
    const session = useSessionStore()
    const roster = useRosterStore()
    return String(session.claims?.hum || useLive().identity.value || roster.self?.id || '')
  }

  function add(rows: unknown[]) {
    const next = mergeFlow(entries.value, rows, self()) as FlowEntry[]
    if (next !== entries.value) entries.value = next
  }

  /** One topic page (before = the cursor of the page above it); its cursor and boundary are kept. */
  async function readPage(before: string) {
    const r = await withSessionRetry(api, () => api.listTopics({ limit: FLOW_TOPICS, perTopic: FLOW_PER_TOPIC, ...(before ? { before } : {}) }))
    const topics = r.topics as Array<{ last_ts?: string, inline?: { messages: SpoolMessage[] } }>
    const rows: SpoolMessage[] = []
    for (const t of topics) {
      if (t.inline) rows.push(...t.inline.messages)
    }
    add(rows)
    next.value = String(r.next || '')
    boundary.value = String((topics.length && topics[topics.length - 1]!.last_ts) || '')
  }

  /** Read older topic pages until the window is full or none is left. */
  async function fill() {
    for (let i = 0; i < FLOW_FILL_PAGES && next.value && visible.value.length < shown.value; i++) {
      await readPage(next.value)
    }
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
      } else if (loaded.value) {
        /* a reconnect: the newest page again, the older pages read so far stay */
        const keep = { next: next.value, boundary: boundary.value }
        await readPage('')
        next.value = keep.next
        boundary.value = keep.boundary
      } else {
        await readPage('')
        await fill()
      }
      loaded.value = true
    } catch (e) {
      error.value = String((e as Error)?.message || e)
    } finally {
      loading.value = false
    }
  }

  /** Load more: a page more of entries, reading older topics when the held ones run out. */
  async function loadMore() {
    if (loadingMore.value || !hasMore.value) return
    loadingMore.value = true
    shown.value += FLOW_PAGE
    try {
      await fill()
    } catch (e) {
      error.value = String((e as Error)?.message || e)
    } finally {
      loadingMore.value = false
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

  return { entries, visible, hasMore, loadingMore, loading, loaded, error, activeKey, opened, ensure, load, loadMore, select, markOpened, drop, self }
})
