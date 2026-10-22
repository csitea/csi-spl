import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { useFlowBadge, useFlowCountsRead, useFlowKeys, useFlowRail } from '~/composables/useFlowBadge'
import { FLOW_PAGE, dropFlow, flowWindow, mergeFlow } from '~/utils/flow-entries.mjs'
import type { FlowEntry } from '~/utils/flow-entries.mjs'
import { flowLineMark, mergeFlowLines, refreshFlowLines } from '~/utils/flow-fold.mjs'
import type { FlowLine } from '~/utils/flow-fold.mjs'
import { FLOW_SCOPE_KEY, FLOW_SEEN_KEY, parseFlowCounts, parseFlowKeys, parseFlowScope, railFromUnread, syncAppBadge } from '~/utils/flow-badge.mjs'
import type { FlowCounts, FlowKind, FlowScope } from '~/utils/flow-badge.mjs'
import { storageGet } from '~/utils/prefs.mjs'
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
/** A live event re-reads the newest folded page after this pause (one read per burst). */
const REFOLD_DEBOUNCE_MS = 400

/** `fn` once, `ms` after the first of a burst of calls (one write or read per burst). */
function burst(ms: number, fn: () => void) {
  let timer: ReturnType<typeof setTimeout> | null = null
  function fire() {
    timer = null
    fn()
  }
  return function soon() {
    if (!timer) timer = setTimeout(fire, ms)
  }
}

function errText(e: unknown) {
  return String((e as Error)?.message || e)
}

/** The store's state: the raw entries (mock fixtures), Mine's folded lines and the badge. */
function flowState(api: ReturnType<typeof useSpoolApi>) {
  return {
    api,
    entries: shallowRef<FlowEntry[]>([]),
    loading: ref(false),
    loaded: ref(false),
    error: ref(''),
    /** The selected entry (keyboard + the last one opened). */
    activeKey: ref(''),
    /** Entries opened from the Flow in this tab: their unread dot goes. */
    opened: shallowRef<Set<string>>(new Set()),
    /** Entries shown: a page, and a page more per Load more. */
    shown: ref(FLOW_PAGE),
    /** The hub's cursor to the next older topic page ('' = none left). */
    next: ref(''),
    /** The oldest read topic's last activity, while an older page is unread. */
    boundary: ref(''),
    loadingMore: ref(false),
    /* spec 062: Mine - only the viewer's flow events, read from the hub
       (GET /v1/view/flow, contract flow-v1), and the Facebook-like number */
    /** Always Mine (spec 130 Q2, owner t1 da98036e: the Mine/All switch is gone).
        MOCK ONLY: the mock bundle still reads FLOW_SCOPE_KEY, so the e2e suites
        that drive entries of the whole mock feed keep their fixture. */
    scope: (api.mock && import.meta.client ? parseFlowScope(storageGet(FLOW_SCOPE_KEY)) : 'mine') as FlowScope,
    /** null = not asked yet; false = this hub has no Flow route (Mine hidden, the pip stays). */
    available: ref<boolean | null>(null),
    /** spec 130: Mine is the hub's folded lines (fold=day), one per topic per UTC day and per UTC day of releases. */
    mine: shallowRef<FlowLine[]>([]),
    mineNext: ref(''),
    mineLoaded: ref(false),
    mineLoading: ref(false),
    /** The chip filter: one kind, '' = all. */
    kind: ref<FlowKind | ''>(''),
    /** The badge: unseen + unread, by kind (hub counts, FR-008). */
    counts: shallowRef<FlowCounts | null>(null),
    /** The chips: unread regardless of f:seen. */
    unread: shallowRef<FlowCounts | null>(null),
    /** The pane is on screen: a new event is seen at once. */
    paneOpen: ref(false),
    badge: useFlowBadge(),
    rail: useFlowRail(),
    /** The hub's unread per sidebar row (owner, t1 77540e6f). */
    rowKeys: useFlowKeys(),
    badgeOn: false,
    following: false,
  }
}

/** What the panel derives from the state, and the two once-per-burst steps. */
function flowViews(s: ReturnType<typeof flowState>) {
  const view = computed(() => flowWindow(s.entries.value, s.shown.value, s.next.value ? s.boundary.value : ''))
  const mineOn = computed(() => s.scope === 'mine' && s.available.value !== false)
  /** What the panel lists: Mine's folded lines, or (mock fixtures only) the newest `shown` entries the read pages vouch for. */
  const visible = computed<Array<FlowLine | FlowEntry>>(() => (mineOn.value ? s.mine.value : view.value.entries as FlowEntry[]))
  const hasMore = computed(() => (mineOn.value ? Boolean(s.mineNext.value) : view.value.more))
  const f = Object.assign(s, { view, mineOn, visible, hasMore, seenSoon: () => {}, refoldSoon: () => {} })
  f.seenSoon = burst(SEEN_DEBOUNCE_MS, () => { void seen(f) })
  /** The hub folds (spec 130 section 2.6): a change re-reads the newest page, once per burst. */
  f.refoldSoon = burst(REFOLD_DEBOUNCE_MS, () => { if (f.mineLoaded.value) void readMine(f, '', true) })
  return f
}

type Flow = ReturnType<typeof flowViews>

function self() {
  const session = useSessionStore()
  const roster = useRosterStore()
  return String(session.claims?.hum || useLive().identity.value || roster.self?.id || '')
}

function add(f: Flow, rows: unknown[]) {
  const next = mergeFlow(f.entries.value, rows, self()) as FlowEntry[]
  if (next !== f.entries.value) f.entries.value = next
}

/** One topic page (before = the cursor of the page above it); its cursor and boundary are kept. */
async function readPage(f: Flow, before: string) {
  const api = f.api
  const r = await withSessionRetry(api, () => api.listTopics({ limit: FLOW_TOPICS, perTopic: FLOW_PER_TOPIC, ...(before ? { before } : {}) }))
  const topics = r.topics as Array<{ last_ts?: string, inline?: { messages: SpoolMessage[] } }>
  const rows: SpoolMessage[] = []
  for (const t of topics) {
    if (t.inline) rows.push(...t.inline.messages)
  }
  add(f, rows)
  f.next.value = String(r.next || '')
  f.boundary.value = String((topics.length && topics[topics.length - 1]!.last_ts) || '')
}

/** Read older topic pages until the window is full or none is left. */
async function fill(f: Flow) {
  for (let i = 0; i < FLOW_FILL_PAGES && f.next.value && f.visible.value.length < f.shown.value; i++) {
    await readPage(f, f.next.value)
  }
}

async function load(f: Flow) {
  if (f.loading.value) return
  f.loading.value = true
  f.error.value = ''
  try {
    if (f.api.mock) {
      /* the mock has no inlined pages: its whole feed is held in memory */
      const r = await f.api.listMessages({ limit: 200 })
      add(f, r.messages)
    } else if (f.loaded.value) {
      /* a reconnect: the newest page again, the older pages read so far stay */
      const keep = { next: f.next.value, boundary: f.boundary.value }
      await readPage(f, '')
      f.next.value = keep.next
      f.boundary.value = keep.boundary
    } else {
      await readPage(f, '')
      await fill(f)
    }
    f.loaded.value = true
  } catch (e) {
    f.error.value = errText(e)
  } finally {
    f.loading.value = false
  }
}

/** Load more: a page more of entries, reading older topics when the held ones run out. */
async function loadMore(f: Flow) {
  if (f.loadingMore.value || !f.hasMore.value) return
  f.loadingMore.value = true
  try {
    if (f.mineOn.value) return await readMine(f, f.mineNext.value)
    f.shown.value += FLOW_PAGE
    await fill(f).catch((e) => { f.error.value = errText(e) })
  } finally {
    f.loadingMore.value = false
  }
}

/** The hub's counts land: the badge, the app icon (FR-013) and, while the pane is open, seen again. */
function setCounts(f: Flow, c: unknown, u: unknown, k?: unknown) {
  const next = parseFlowCounts(c)
  if (next) f.counts.value = next
  const chips = parseFlowCounts(u)
  if (chips) {
    f.unread.value = chips
    f.rail.value = railFromUnread(chips)
  }
  const perRow = parseFlowKeys(k)
  if (perRow) f.rowKeys.value = perRow
  if (!f.counts.value) return
  f.available.value = true
  f.badge.value = f.counts.value.total
  if (import.meta.client) syncAppBadge(navigator, f.badge.value)
  if (f.paneOpen.value && f.counts.value.total > 0) f.seenSoon()
}

/** A failed Flow read: a hub without the route (404) or no member session (403) turns Mine off. */
function flowRefused(f: Flow, e: unknown) {
  const status = Number((e as { status?: number })?.status || 0)
  if (status === 404 || status === 403 || status === 405) {
    f.available.value = false
    f.badge.value = -1
    return true
  }
  return false
}

/**
 * One Mine page: before = the hub's `next` (an older page, added below);
 * '' = the newest page, which replaces the held ones, or with `refresh`
 * goes over them and keeps the older pages and their cursor.
 */
async function readMine(f: Flow, before: string, refresh = false) {
  const api = f.api
  f.mineLoading.value = true
  f.error.value = ''
  try {
    const r = await withSessionRetry(api, () => api.listFlow({ limit: FLOW_PAGE, before, kind: f.kind.value, self: self(), fold: true }))
    /* the cursor is the raw event the hub stopped at (contract flow-fold-v1 section 3) */
    if (before) f.mine.value = mergeFlowLines(f.mine.value, r.lines)
    else if (refresh && f.mineLoaded.value) {
      /* a live event or a reconnect: the newest page over the older pages read so far */
      f.mine.value = refreshFlowLines(r.lines, f.mine.value)
      return void setCounts(f, r.counts, r.unread, r.keys)
    } else f.mine.value = r.lines
    f.mineNext.value = String(r.next || '')
    f.mineLoaded.value = true
    setCounts(f, r.counts, r.unread, r.keys)
  } catch (e) {
    if (!flowRefused(f, e)) f.error.value = errText(e)
  } finally {
    f.mineLoading.value = false
  }
}

/** The badge alone (startup, reconnect): one statement on the hub. */
async function readCounts(f: Flow) {
  const api = f.api
  try {
    const r = await withSessionRetry(api, () => api.listFlow({ countsOnly: true, self: self() }))
    setCounts(f, r.counts, r.unread, r.keys)
  } catch (e) {
    flowRefused(f, e)
  }
  /* SPL-2815: after the render that showed them (the sidebar's swell waits) */
  const read = useFlowCountsRead()
  if (!read.value) void nextTick(() => { read.value = true })
}

/** Start the number (the sidebar calls this once, lazily): counts now, then the hub's frames. */
function startBadge(f: Flow) {
  if (f.badgeOn || !import.meta.client) return
  f.badgeOn = true
  const live = useLive()
  /** A `flow` frame: the hub's counts, and with a new event the newest folded page again. */
  const onFlowFrame = (fr: Record<string, unknown>) => {
    setCounts(f, fr.counts, fr.unread, fr.keys)
    if (fr.event && f.mineLoaded.value) f.refoldSoon()
  }
  live.onFlow(onFlowFrame)
  live.onReconnected(() => {
    void readCounts(f)
    if (f.mineLoaded.value) void readMine(f, '', true)
  })
  /* owner (t1 56b8cc17): an archived topic leaves every unread number at once */
  window.addEventListener('spool:topic-archived', () => { void readCounts(f) }) /* spool-client-lazy archiveTopic */
  void readCounts(f)
}

/**
 * The pane opened (Q4): the number goes to 0 here at once and the f:seen
 * mark tells the hub, which pushes a counts frame to the member's other
 * tabs and devices (FR-007). The entries stay unread until opened.
 */
async function seen(f: Flow) {
  if (!f.counts.value || f.counts.value.total === 0) return
  f.counts.value = { mention: 0, reply: 0, dm: 0, total: 0 }
  f.badge.value = 0
  syncAppBadge(navigator, 0)
  try {
    await f.api.markFlow({ [FLOW_SEEN_KEY]: { ts: new Date().toISOString() } })
    if (f.api.mock) await readCounts(f)
  } catch {
    /* the next open marks it again; the hub's next frame corrects the number */
  }
}

/** A chip: that kind only; the same chip again shows every kind. */
function setKind(f: Flow, next: FlowKind | '') {
  f.kind.value = f.kind.value === next ? '' : next
  f.mine.value = []
  f.mineNext.value = ''
  void readMine(f, '')
}

/** A line shows this message (its newest event): an edit or a delete re-folds. */
function holdsMsg(f: Flow, msgId: string) {
  return Boolean(msgId) && f.mine.value.some((l) => l.msg_id === msgId)
}

/** A message gone (a live frame or deleted here) leaves the stream too. */
function drop(f: Flow, msgId: string) {
  f.entries.value = dropFlow(f.entries.value, msgId) as FlowEntry[]
  if (holdsMsg(f, msgId)) f.refoldSoon()
}

/** Live frames: the tab-wide `all` follow (plugins/spool-live.client.ts) feeds them. */
function follow(f: Flow) {
  if (f.following || !import.meta.client) return
  f.following = true
  const live = useLive()
  live.onMessage((m) => add(f, [m]))
  live.onEdited((m) => {
    add(f, [m])
    if (holdsMsg(f, String(m.msg_id || ''))) f.refoldSoon()
  })
  live.onDeleted((m) => drop(f, String(m.msg_id || '')))
  live.onReconnected(() => { void load(f) })
}

/** Open the Flow: the first time reads it, later only the mock re-reads (it has no socket). */
function ensure(f: Flow) {
  follow(f)
  startBadge(f)
  if (f.mineOn.value) {
    if (!f.mineLoaded.value || f.api.mock) void readMine(f, '')
    return
  }
  if (!f.loaded.value || f.api.mock) void load(f)
}

function markOpened(f: Flow, key: string) {
  if (!key || f.opened.value.has(key)) return
  f.opened.value = new Set([...f.opened.value, key])
  /* spec 130 FR-009: opening a folded line marks all of it read on every
     device: t:<task_id> at its newest event, a release line f:rel:<version> */
  const line = f.mine.value.find((r) => r.key === key)
  if (!line || !line.unread) return
  f.mine.value = f.mine.value.map((r) => (r.key === key ? { ...r, unread: false } : r))
  void f.api.markFlow(flowLineMark(line))
    .then(() => (f.api.mock ? readCounts(f) : undefined))
    .catch(() => { /* the place's own read mark still covers it later */ })
}

/**
 * Flow (topic 635f8072): the stream of short message entries in the left
 * panel, newest first. The first read is the newest topics with their last
 * few messages inlined (one request); live frames then add to the top, an
 * edit replaces its entry and a delete drops it. The selection lives here
 * too, so the list keeps it while the middle pane changes route.
 */
export const useFlowStore = defineStore('flow', () => {
  const f = flowViews(flowState(useSpoolApi()))
  const { available, mineOn, mine, mineLoading, mineLoaded, kind, counts, unread, paneOpen } = f
  const { entries, visible, hasMore, loadingMore, loading, loaded, error, activeKey, opened } = f
  return {
    available, mineOn, mine, mineLoading, mineLoaded, kind, counts, unread, paneOpen,
    startBadge: () => startBadge(f),
    readCounts: () => readCounts(f),
    seen: () => seen(f),
    /** The pane shows (true) or hides (false). */
    setPaneOpen(on: boolean) {
      paneOpen.value = on
      if (on) void seen(f)
    },
    setKind: (next: FlowKind | '') => setKind(f, next),
    entries, visible, hasMore, loadingMore, loading, loaded, error, activeKey, opened,
    ensure: () => ensure(f),
    load: () => load(f),
    loadMore: () => loadMore(f),
    select(key: string) {
      activeKey.value = key
    },
    markOpened: (key: string) => markOpened(f, key),
    drop: (msgId: string) => drop(f, msgId),
    self,
  }
})
