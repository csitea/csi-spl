import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { useFlowBadge, useFlowKeys, useFlowRail } from '~/composables/useFlowBadge'
import { FLOW_PAGE, dropFlow, flowWindow, mergeFlow, mergeMine } from '~/utils/flow-entries.mjs'
import type { FlowEntry } from '~/utils/flow-entries.mjs'
import { FLOW_SCOPE_KEY, FLOW_SEEN_KEY, parseFlowCounts, parseFlowKeys, parseFlowScope, railFromUnread, syncAppBadge } from '~/utils/flow-badge.mjs'
import type { FlowCounts, FlowKind, FlowScope } from '~/utils/flow-badge.mjs'
import { storageGet, storageSet } from '~/utils/prefs.mjs'
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
/** While the pane is open, a new event re-marks it seen after this pause (one write per burst). */
const SEEN_DEBOUNCE_MS = 400

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

  /* spec 062: Mine - only the viewer's flow events, read from the hub
     (GET /v1/view/flow, contract flow-v1), and the Facebook-like number */
  /** Mine (default, Q1) or All (today's stream); kept per browser. */
  const scope = ref<FlowScope>(parseFlowScope(import.meta.client ? storageGet(FLOW_SCOPE_KEY) : ''))
  /** null = not asked yet; false = this hub has no Flow route (Mine hidden, the pip stays). */
  const available = ref<boolean | null>(null)
  const mine = shallowRef<FlowEntry[]>([])
  const mineNext = ref('')
  const mineLoaded = ref(false)
  const mineLoading = ref(false)
  /** The chip filter: one kind, '' = all. */
  const kind = ref<FlowKind | ''>('')
  /** The badge: unseen + unread, by kind (hub counts, FR-008). */
  const counts = shallowRef<FlowCounts | null>(null)
  /** The chips: unread regardless of f:seen. */
  const unread = shallowRef<FlowCounts | null>(null)
  /** The pane is on screen: a new event is seen at once. */
  const paneOpen = ref(false)
  const badge = useFlowBadge()
  const rail = useFlowRail()
  /** The hub's unread per sidebar row (owner, t1 77540e6f). */
  const rowKeys = useFlowKeys()
  const mineOn = computed(() => scope.value === 'mine' && available.value !== false)

  /** What the panel lists: Mine's held events, or the newest `shown` entries the read pages vouch for. */
  const visible = computed(() => (mineOn.value ? mine.value : view.value.entries as FlowEntry[]))
  const hasMore = computed(() => (mineOn.value ? Boolean(mineNext.value) : view.value.more))

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
    if (mineOn.value) {
      loadingMore.value = true
      try {
        await readMine(mineNext.value)
      } finally {
        loadingMore.value = false
      }
      return
    }
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

  /** The hub's counts land: the badge, the app icon (FR-013) and, while the pane is open, seen again. */
  function setCounts(c: unknown, u: unknown, k?: unknown) {
    const next = parseFlowCounts(c)
    if (next) counts.value = next
    const chips = parseFlowCounts(u)
    if (chips) {
      unread.value = chips
      rail.value = railFromUnread(chips)
    }
    const perRow = parseFlowKeys(k)
    if (perRow) rowKeys.value = perRow
    if (!counts.value) return
    available.value = true
    badge.value = counts.value.total
    if (import.meta.client) syncAppBadge(navigator, badge.value)
    if (paneOpen.value && counts.value.total > 0) seenSoon()
  }

  /** A failed Flow read: a hub without the route (404) or no member session (403) turns Mine off. */
  function flowRefused(e: unknown) {
    const status = Number((e as { status?: number })?.status || 0)
    if (status === 404 || status === 403 || status === 405) {
      available.value = false
      badge.value = -1
      return true
    }
    return false
  }

  /** One Mine page (before = the last event's cursor; '' = the newest page, which replaces the held ones). */
  async function readMine(before: string) {
    mineLoading.value = true
    error.value = ''
    try {
      const r = await withSessionRetry(api, () => api.listFlow({ limit: FLOW_PAGE, before, kind: kind.value, self: self() }))
      const held = before ? mine.value : []
      mine.value = mergeMine(held, r.events, self()) as FlowEntry[]
      const last = r.events[r.events.length - 1] as { cursor?: unknown } | undefined
      mineNext.value = r.next ? String((last && last.cursor) || r.next) : ''
      mineLoaded.value = true
      setCounts(r.counts, r.unread, r.keys)
    } catch (e) {
      if (!flowRefused(e)) error.value = String((e as Error)?.message || e)
    } finally {
      mineLoading.value = false
    }
  }

  /** The badge alone (startup, reconnect): one statement on the hub. */
  async function readCounts() {
    try {
      const r = await withSessionRetry(api, () => api.listFlow({ countsOnly: true, self: self() }))
      setCounts(r.counts, r.unread, r.keys)
    } catch (e) {
      flowRefused(e)
    }
  }

  /** A `flow` frame: the hub's counts, and the new event when there is one. */
  function onFlowFrame(f: Record<string, unknown>) {
    setCounts(f.counts, f.unread, f.keys)
    const ev = f.event as { kind?: string } | null | undefined
    if (!ev || !mineLoaded.value) return
    const k = ev.kind === 'poke' ? 'mention' : ev.kind
    if (kind.value && k !== kind.value) return
    mine.value = mergeMine(mine.value, [ev], self()) as FlowEntry[]
  }

  let badgeOn = false
  /** Start the number (the sidebar calls this once, lazily): counts now, then the hub's frames. */
  function startBadge() {
    if (badgeOn || !import.meta.client) return
    badgeOn = true
    const live = useLive()
    live.onFlow(onFlowFrame)
    live.onReconnected(() => {
      void readCounts()
      if (mineLoaded.value) void readMine('')
    })
    void readCounts()
  }

  let seenTimer: ReturnType<typeof setTimeout> | null = null
  function seenSoon() {
    if (seenTimer) return
    seenTimer = setTimeout(() => {
      seenTimer = null
      void seen()
    }, SEEN_DEBOUNCE_MS)
  }

  /**
   * The pane opened (Q4): the number goes to 0 here at once and the f:seen
   * mark tells the hub, which pushes a counts frame to the member's other
   * tabs and devices (FR-007). The entries stay unread until opened.
   */
  async function seen() {
    if (!counts.value || counts.value.total === 0) return
    counts.value = { mention: 0, reply: 0, dm: 0, total: 0 }
    badge.value = 0
    syncAppBadge(navigator, 0)
    try {
      await api.markFlow({ [FLOW_SEEN_KEY]: { ts: new Date().toISOString() } })
      if (api.mock) await readCounts()
    } catch {
      /* the next open marks it again; the hub's next frame corrects the number */
    }
  }

  /** The pane shows (true) or hides (false). */
  function setPaneOpen(on: boolean) {
    paneOpen.value = on
    if (on) void seen()
  }

  /** Mine / All (FR-012): the choice is kept in this browser. */
  function setScope(next: FlowScope) {
    scope.value = parseFlowScope(next)
    storageSet(FLOW_SCOPE_KEY, scope.value)
    ensure()
  }

  /** A chip: that kind only; the same chip again shows every kind. */
  function setKind(next: FlowKind | '') {
    kind.value = kind.value === next ? '' : next
    mine.value = []
    mineNext.value = ''
    void readMine('')
  }

  let following = false
  /** Live frames: the tab-wide `all` follow (plugins/spool-live.client.ts) feeds them. */
  function follow() {
    if (following || !import.meta.client) return
    following = true
    const live = useLive()
    live.onMessage((m) => add([m]))
    live.onEdited((m) => {
      add([m])
      if (mine.value.some((e) => e.key === String(m.msg_id || ''))) refreshMine(m)
    })
    live.onDeleted((m) => {
      entries.value = dropFlow(entries.value, String(m.msg_id || '')) as FlowEntry[]
      mine.value = dropFlow(mine.value, String(m.msg_id || '')) as FlowEntry[]
    })
    live.onReconnected(() => { void load() })
  }

  /** An edit of a Mine entry: its text changes, its kind and unread verdict stay. */
  function refreshMine(m: Record<string, unknown>) {
    const held = mine.value.find((e) => e.key === String(m.msg_id || ''))
    if (!held) return
    mine.value = mergeMine(mine.value, [{ ...m, kind: held.event, unread: held.fresh ?? undefined }], self()) as FlowEntry[]
  }

  /** Open the Flow: the first time reads it, later only the mock re-reads (it has no socket). */
  function ensure() {
    follow()
    startBadge()
    if (mineOn.value) {
      if (!mineLoaded.value || api.mock) void readMine('')
      return
    }
    if (!loaded.value || api.mock) void load()
  }

  function select(key: string) {
    activeKey.value = key
  }

  function markOpened(key: string) {
    if (!key || opened.value.has(key)) return
    opened.value = new Set([...opened.value, key])
    /* FR-006: a Mine entry opened from the Flow is read on every device (f:<msg_id>) */
    const e = mine.value.find((r) => r.key === key)
    if (!e || e.fresh === false) return
    void api.markFlow({ ['f:' + e.msg_id]: { ts: new Date().toISOString(), id: e.msg_id } })
      .then(() => (api.mock ? readCounts() : undefined))
      .catch(() => { /* the place's own read mark still covers it later */ })
  }

  /** A message deleted here (not a live frame) leaves the stream too. */
  function drop(msgId: string) {
    entries.value = dropFlow(entries.value, msgId) as FlowEntry[]
    mine.value = dropFlow(mine.value, msgId) as FlowEntry[]
  }

  return {
    scope, available, mineOn, mine, mineLoading, mineLoaded, kind, counts, unread, paneOpen,
    startBadge, readCounts, seen, setPaneOpen, setScope, setKind, entries, visible, hasMore, loadingMore, loading, loaded, error, activeKey, opened, ensure, load, loadMore, select, markOpened, drop, self }
})
