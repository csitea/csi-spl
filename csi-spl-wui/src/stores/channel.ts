import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import {
  belongsTo,
  channelFollow,
  channelView,
  dmFollow,
  mergePage,
  channelSlug,
  feedRow,
  followPlan,
  mergeLive,
  rowFromAck,
  parseMention,
  rootsByTask,
  threadReplies,
  topLevel,
} from '~/utils/channel-feed.mjs'
import { loadCursors, readMap } from '~/utils/read-cursor.mjs'
import { pendingRow, withoutMsg } from '~/utils/feed.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import type { ChannelRow, SendFrame, SpoolMessage } from '~/types/spool'

export type { ChannelRow }

/** view-v1 §4.2 extras the sidebar reads (hub rows; mock rows lack them). */
export type ChannelInfo = ChannelRow & {
  retention_days?: number
  unread?: number
  last_ts?: string | null
  last_cursor?: string | null
}

type FeedMessage = SpoolMessage & { count?: number, thread_row?: boolean }

const WINDOW = 50

function newId() {
  return globalThis.crypto && globalThis.crypto.randomUUID ? globalThis.crypto.randomUUID() : ''
}

export const useChannelStore = defineStore('channel', () => {
  const api = useSpoolApi()
  /* the global i18n instance for the fallback error lines (a hub error keeps its own message) */
  const i18n = useNuxtApp().$i18n
  const channels = ref<ChannelInfo[]>([])
  const active = ref<string | null>(null)
  const peer = ref<string | null>(null)
  const messages = ref<FeedMessage[]>([])
  const unread = ref<Record<string, number>>({})
  const loading = ref(false)
  const error = ref<string | null>(null)

  const feed = computed(() => rootsByTask(topLevel(messages.value)))
  /* 013 on /channel and /dm (X3): newest first under the Omnibox, windowed, /search filtered */
  const search = ref('')
  const visible = ref(WINDOW)
  const lastLive = ref<FeedMessage | null>(null)
  /** view-v1 §4.3 cursor for the next older thread page; null = none left. */
  const olderCursor = ref<string | null>(null)
  let loadingOlder = false
  const view = computed(() => channelView(messages.value, { search: search.value, visible: visible.value }))
  const newestFirst = computed(() => view.value.rows as FeedMessage[])
  const hasOlder = computed(() => view.value.hasOlder || Boolean(olderCursor.value))
  const followed = new Set<string>()
  let followedChannel = ''
  let followedPeer = ''

  /** Live: subscribe the socket to every thread on screen, drop the ones that left. */
  function follow() {
    if (api.mock || !import.meta.client) return
    const live = useLive()
    const client = live.ensure()
    if (!client) return
    const want = feed.value.map((m) => String(m.task_id || ''))
    const plan = followPlan(followed, want, live.lobbyTaskId.value)
    for (const t of plan.add) { client.subscribe(t); followed.add(t) }
    for (const t of plan.drop) { client.unsubscribe(t); followed.delete(t) }
    /* the open channel itself, so a root someone else starts there arrives live (H4) */
    const c = channelFollow(followedChannel, { channel: active.value, peer: peer.value })
    if (c.unsub) client.unsubscribeChannel(c.unsub)
    if (c.sub) client.subscribeChannel(c.sub)
    followedChannel = c.next
    /* the open DM, so a new DM root either side starts arrives live (013 US7, wui-live-ws v0.5) */
    const d = dmFollow(followedPeer, { peer: peer.value })
    if (d.unsub) client.unsubscribePeer(d.unsub)
    if (d.sub) client.subscribePeer(d.sub)
    followedPeer = d.next
  }

  function key() {
    return peer.value ? `dm:${peer.value}` : `ch:${active.value || ''}`
  }

  /** Live: send read=<ch>~<cursor> so the hub counts unread per reader (channels-v1 §5.2). */
  async function loadChannels() {
    const read: Record<string, string> = api.mock ? {} : readMap(loadCursors()) as Record<string, string>
    /* a member's first read of a fresh page flips the door to the session cookie (010 FR-009), as the lobby does */
    channels.value = await withSessionRetry(api, () => api.listChannels({ read })) as ChannelInfo[]
  }

  function resetView() {
    search.value = ''
    visible.value = WINDOW
    lastLive.value = null
    olderCursor.value = null
  }

  /**
   * Bottom sentinel: reveal the next older window of rows already held, then
   * fetch the next §4.3 thread page (`before=<next>`), append older rows at
   * the BOTTOM (storage stays oldest-first; channelView sorts newest-first),
   * de-duplicated by msg_id. Stops when `next` is null.
   */
  async function loadOlder() {
    if (view.value.hasOlder) {
      visible.value += WINDOW
      return
    }
    if (!olderCursor.value || loadingOlder) return
    loadingOlder = true
    try {
      const page = await withSessionRetry(api, () => api.listMessages({
        channel: active.value || undefined,
        peer: peer.value || undefined,
        limit: 50,
        before: olderCursor.value || undefined,
      }))
      const incoming = (page.messages || []).map(feedRow) as unknown as FeedMessage[]
      const seen = new Set(messages.value.map((m) => m.msg_id))
      const add = incoming.filter((m) => m.msg_id && !seen.has(m.msg_id))
      if (add.length) messages.value = [...messages.value, ...add]
      olderCursor.value = page.next || null
      visible.value += WINDOW
      follow()
    } catch (e) {
      error.value = e instanceof Error ? e.message : i18n.t('feed.error.load_older_failed')
      olderCursor.value = null
    } finally {
      loadingOlder = false
    }
  }

  function setSearch(q: string) {
    search.value = q
    visible.value = WINDOW
  }

  async function selectChannel(name: string) {
    if (active.value !== name || peer.value) resetView()
    peer.value = null
    active.value = name
    unread.value[name] = 0
    await refresh()
  }

  async function selectDm(id: string) {
    if (peer.value !== id) resetView()
    active.value = null
    peer.value = id
    unread.value[`dm:${id}`] = 0
    await refresh()
  }

  async function refresh() {
    loading.value = true
    error.value = null
    try {
      const page = await withSessionRetry(api, () => api.listMessages({
        channel: active.value || undefined,
        peer: peer.value || undefined,
        limit: 50,
      }))
      messages.value = (page.messages || []).map(feedRow) as unknown as FeedMessage[]
      olderCursor.value = page.next || null
      follow()
    } catch (e) {
      error.value = e instanceof Error ? e.message : i18n.t('feed.error.load_failed')
    } finally {
      loading.value = false
    }
  }

  /**
   * After a socket reconnect (013 US7 FR-015): re-read the first page and
   * merge it by msg_id, so older pages already loaded and pending sends stay.
   */
  async function catchUp() {
    if (api.mock) return refresh()
    const where = { channel: active.value, peer: peer.value }
    try {
      const page = await withSessionRetry(api, () => api.listMessages({ channel: where.channel || undefined, peer: where.peer || undefined, limit: 50 }))
      if (where.channel !== active.value || where.peer !== peer.value) return
      messages.value = mergePage(messages.value, (page.messages || []).map(feedRow) as unknown as FeedMessage[])
      follow()
    } catch (e) {
      error.value = e instanceof Error ? e.message : i18n.t('feed.error.catch_up_failed')
    }
  }

  /** One live WS message (useSpoolEvents): no poll in live mode. */
  function ingestLive(m: Record<string, unknown>) {
    if (!belongsTo(m, { channel: active.value, peer: peer.value })) return
    const before = messages.value
    messages.value = mergeLive(before, m) as FeedMessage[]
    if (messages.value !== before) lastLive.value = m as unknown as FeedMessage
    follow()
  }

  async function send(text: string, parentTaskId?: string, files?: unknown[]) {
    if (!api.mock) return sendLive(text, parentTaskId, files)
    const body = await api.sendMessage({
      channel: active.value,
      peer: peer.value || undefined,
      text,
      parent_task_id: parentTaskId,
      files,
    })
    const row = body as unknown as FeedMessage
    messages.value = [...messages.value, row]
    return row
  }

  /** Live send over the hub WUI socket (wui-live-ws §4); the echo frame lands via ingestLive. */
  async function sendLive(text: string, parentTaskId?: string, files?: unknown[]) {
    const live = useLive()
    const client = live.ensure()
    if (!client) throw new Error(`live socket unavailable (${api.configError || 'no base'})`)
    const [peerId] = String(peer.value || '').split('@')
    const parsed = parseMention(text)
    const frame: SendFrame = {
      task_id: parentTaskId || newId(),
      kind: peer.value ? 'note' : parsed.kind,
      body: peer.value ? text : parsed.body,
      files: files || [],
      to: peer.value ? peerId : (parsed.to === '@channel' ? undefined : parsed.to),
    }
    if (active.value) frame.channel = active.value
    /* 013 US7 FR-013: our card shows at once under the msg_id we send; echo / ack replace it */
    frame.msg_id = newId() || undefined
    const channelNow = active.value
    if (frame.msg_id) {
      const own = pendingRow({
        msg_id: frame.msg_id, task_id: frame.task_id, from: live.identity.value, to: frame.to || '@channel',
        kind: frame.kind, body: frame.body, files: frame.files, channel: channelNow,
      })
      messages.value = mergeLive(messages.value, own) as FeedMessage[]
    }
    let ack
    try {
      ack = await client.send(frame)
    } catch (e) {
      if (frame.msg_id) messages.value = withoutMsg(messages.value, frame.msg_id) as FeedMessage[]
      throw e
    }
    const row = rowFromAck(ack, frame, { from: live.identity.value, channel: channelNow })
    if (row.msg_id) {
      messages.value = mergeLive(messages.value, row) as FeedMessage[]
      follow()
    }
    return ack
  }

  async function createChannel(name: string) {
    const slug = channelSlug(name)
    if (!slug) throw new Error(i18n.t('sidebar.channel_name_required'))
    const row = await withSessionRetry(api, () => api.createChannel({ channel_id: slug, name }))
    const id = String(row.channel_id || slug)
    await loadChannels()
    await selectChannel(id)
    return { ...row, channel_id: id }
  }

  function repliesFor(taskId: string) {
    return threadReplies(messages.value, taskId)
  }

  return {
    channels,
    active,
    peer,
    messages,
    unread,
    loading,
    error,
    feed,
    newestFirst,
    hasOlder,
    search,
    lastLive,
    loadOlder,
    setSearch,
    key,
    loadChannels,
    selectChannel,
    selectDm,
    refresh,
    ingestLive,
    catchUp,
    send,
    createChannel,
    repliesFor,
  }
})
