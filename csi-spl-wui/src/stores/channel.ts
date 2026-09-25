import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { emptySendError, isEmptySend, shouldAutoResend } from '~/utils/send-failure.mjs'
import {
  addChannelRow,
  belongsTo,
  channelFollow,
  channelView,
  dmFollow,
  mergePage,
  channelSlug,
  dmActivity,
  feedRow,
  followPlan,
  mergeLive,
  noteActivity,
  orderChannels,
  rowFromAck,
  parseMention,
  rootsByTask,
  topicReplies,
  topLevel,
} from '~/utils/channel-feed.mjs'
import { loadCursors, readMap } from '~/utils/read-cursor.mjs'
import { pendingRow, withoutMsg } from '~/utils/feed.mjs'
import { applyEdit } from '~/utils/msg-edit.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import type { ChannelRow, FileRef, SendFrame, SpoolMessage } from '~/types/spool'

export type { ChannelRow }

/** view-v1 §4.2 extras the sidebar reads (hub rows; mock rows lack them). */
export type ChannelInfo = ChannelRow & {
  retention_days?: number
  unread?: number
  last_ts?: string | null
  last_cursor?: string | null
}

type FeedMessage = SpoolMessage & { count?: number, topic_row?: boolean }

/** One page of the Msgs list: the first paint and every Load more. */
export const WINDOW = 30

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
  /**
   * CLE-3425 — last activity per channel id and per DM peer label, fed by the
   * tab-wide `all` follow (plugins/spool-live.client.ts). The sidebar orders
   * both lists by it, so a message in a channel nobody has open still moves
   * that channel to the top with no refetch and no reload.
   */
  const liveAt = ref<Record<string, string>>({})
  const dmAt = ref<Record<string, string>>({})
  /** The sidebar's channel list: newest activity first (CLE-3425). */
  const ordered = computed(() => orderChannels(channels.value, liveAt.value) as ChannelInfo[])

  const feed = computed(() => rootsByTask(topLevel(messages.value)))
  /* 013 on /channel and /dm (X3): newest first under the Omnibox, windowed, /search filtered */
  const search = ref('')
  const visible = ref(WINDOW)
  const lastLive = ref<FeedMessage | null>(null)
  /** view-v1 §4.3 cursor for the next older topic page; null = none left. */
  const olderCursor = ref<string | null>(null)
  const loadingOlder = ref(false)
  const view = computed(() => channelView(messages.value, { search: search.value, visible: visible.value }))
  const newestFirst = computed(() => view.value.rows as FeedMessage[])
  const hasOlder = computed(() => view.value.hasOlder || Boolean(olderCursor.value))
  const followed = new Set<string>()
  let followedChannel = ''
  let followedPeer = ''

  /** Live: subscribe the socket to every topic on screen, drop the ones that left. */
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

  /**
   * CLE-3425 — one live frame into the sidebar's order. Called for EVERY frame
   * of the tenant, not only the open view's (ingestLive keeps that filter).
   */
  function noteLive(m: Record<string, unknown>, self = '') {
    const next = noteActivity({ channels: liveAt.value, peers: dmAt.value }, m, self)
    if (next.channels !== liveAt.value) liveAt.value = next.channels
    if (next.peers !== dmAt.value) dmAt.value = next.peers
  }

  /** CLE-3425 — a channel created anywhere in the tenant (hub `channel` frame). */
  function addChannel(frame: Record<string, unknown>) {
    channels.value = addChannelRow(channels.value, frame) as ChannelInfo[]
  }

  /**
   * CLE-3425 — the last DM per peer, so the DM list is ordered by activity on
   * the first paint too (live frames keep it fresh afterwards). A hub without
   * the route, or a closed door, leaves the previous map alone.
   */
  async function loadDmActivity(self = '') {
    if (api.mock) return
    try {
      const page = await withSessionRetry(api, () => api.listTopics({ dm: true, limit: 50 }))
      dmAt.value = { ...dmAt.value, ...dmActivity(page.topics, self) }
    } catch {
      /* the sidebar still lists peers; only the order falls back to a-z */
    }
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
   * Load more: reveal the next older window of rows already held, then
   * fetch the next §4.3 topic page (`before=<next>`), append older rows at
   * the BOTTOM (storage stays oldest-first; channelView sorts newest-first),
   * de-duplicated by msg_id. Stops when `next` is null.
   */
  async function loadOlder() {
    if (view.value.hasOlder) {
      visible.value += WINDOW
      return
    }
    if (!olderCursor.value || loadingOlder.value) return
    loadingOlder.value = true
    try {
      const page = await withSessionRetry(api, () => api.listMessages({
        channel: active.value || undefined,
        peer: peer.value || undefined,
        limit: WINDOW,
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
      loadingOlder.value = false
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
        limit: WINDOW,
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

  /**
   * CLE-3445: a message this store holds was edited — here, or in another
   * session via a `message_edited` frame. applyEdit replaces it at its index
   * and never re-sorts (FR-ED-009: an edit does not move the message), and
   * ignores a msg_id this feed does not hold.
   */
  function applyEdited(row: unknown) {
    messages.value = applyEdit(messages.value, row) as FeedMessage[]
  }

  /** One live WS message (useSpoolEvents): no poll in live mode. */
  function ingestLive(m: Record<string, unknown>) {
    if (!belongsTo(m, { channel: active.value, peer: peer.value })) return
    const before = messages.value
    messages.value = mergeLive(before, m) as FeedMessage[]
    if (messages.value !== before) lastLive.value = m as unknown as FeedMessage
    follow()
  }

  async function send(text: string, parentTaskId?: string, files?: unknown[], channelId?: string, isParent?: number) {
    if (!api.mock) return sendLive(text, parentTaskId, files, channelId, isParent)
    const body = await api.sendMessage({
      channel: channelId || active.value,
      peer: channelId ? undefined : (peer.value || undefined),
      text,
      parent_task_id: parentTaskId,
      is_parent: isParent === 0 ? 0 : 1,
      files,
    })
    const row = body as unknown as FeedMessage
    /* a reply into another channel must not appear in this feed */
    if (!channelId || channelId === active.value) messages.value = [...messages.value, row]
    return row
  }

  /**
   * CLE-3433: a picked File is not a wire value. `stores/live.ts` POSTs each
   * one to /v1/files first and puts the returned ref on the frame; this store
   * never did, so /channel and /dm offered the attach control and then sent a
   * frame with no files at all. Measured on the deployed dev build bb20552,
   * signed in, WS frames captured and held back (n=1 per route): /lobby put
   * 1 file on the frame, /dm and /channel put 0 - and the chip vanished from
   * the composer either way, so it LOOKED sent.
   *
   * Anything that is already a ref passes through untouched, which is what
   * makes the auto-resend on a dropped socket safe: the retry reuses the same
   * frame and must not upload a second time.
   */
  async function toFileRefs(files?: unknown[]) {
    const refs: FileRef[] = []
    for (const f of files || []) {
      if (typeof Blob !== 'undefined' && f instanceof Blob) {
        const live = useLive()
        const up = await api.uploadFile(f, await live.freshUploadToken()) as { file_id: string, sha256: string, bytes: number }
        refs.push({ mode: 'blob', kind: 'file', file_id: up.file_id, sha256: up.sha256, bytes: up.bytes, name: (f as File).name })
      } else if (f) {
        refs.push(f as FileRef)
      }
    }
    return refs
  }

  /**
   * Live send over the hub WUI socket (wui-live-ws §4); the echo frame lands via ingestLive.
   * `channelId` is the channel an `in:` clause named. It is a channel post even
   * when this page is a DM, and the row stays out of this feed when that
   * channel is not the one on screen.
   */
  async function sendLive(text: string, parentTaskId?: string, files?: unknown[], channelId?: string, isParent?: number) {
    const live = useLive()
    const client = live.ensure()
    if (!client) throw new Error(`live socket unavailable (${api.configError || 'no base'})`)
    const [peerId] = String(peer.value || '').split('@')
    const parsed = parseMention(text)
    const asDm = !channelId && Boolean(peer.value)
    const parentBit: 0 | 1 = isParent === 0 ? 0 : 1
    const frame: SendFrame = {
      task_id: parentTaskId || newId(),
      kind: asDm ? 'note' : parsed.kind,
      body: asDm ? text : parsed.body,
      files: await toFileRefs(files),
      to: asDm ? peerId : (parsed.to === '@channel' ? undefined : parsed.to),
      is_parent: parentBit,
    }
    const channelNow = channelId || active.value
    if (channelNow) frame.channel = channelNow
    /* CLE-3433: `@CLE-00` alone parses to a task frame with an EMPTY body.
       The composer cannot catch it - it only sees the text before the
       mention is stripped - so the refusal lives here, where the real
       payload is known. An empty row reads exactly like a lost one. */
    if (isEmptySend(frame.body, frame.files)) throw emptySendError()
    /* 013 US7 FR-013: our card shows at once under the msg_id we send; echo / ack replace it */
    frame.msg_id = newId() || undefined
    const showHere = !channelId || channelId === active.value
    if (frame.msg_id && showHere) {
      const own = pendingRow({
        msg_id: frame.msg_id, task_id: frame.task_id, from: live.identity.value, to: frame.to || '@channel',
        kind: frame.kind, body: frame.body, files: frame.files, channel: channelNow,
        is_parent: parentBit,
      })
      messages.value = mergeLive(messages.value, own) as FeedMessage[]
    }
    /* CLE-3433: one automatic resend when the socket went away underneath a
       pending frame. The frame carries our own msg_id, so the hub de-dupes
       the race where the first copy did land, and live-ws will have queued
       and flushed on the new socket by the time this second call runs. Any
       other failure is REPORTED, not retried - see utils/send-failure.mjs.

       The optimistic row stays put across the retry: rolling it back was half
       of how the owner's message disappeared without a trace on 2026-09-21.
       It is removed only when the send has definitively failed, and by then
       the caller is showing the text again with a Retry. */
    let ack
    try {
      ack = await client.send(frame)
    } catch (first) {
      if (!shouldAutoResend(first)) {
        if (frame.msg_id && showHere) messages.value = withoutMsg(messages.value, frame.msg_id) as FeedMessage[]
        throw first
      }
      try {
        ack = await client.send(frame)
      } catch (second) {
        if (frame.msg_id && showHere) messages.value = withoutMsg(messages.value, frame.msg_id) as FeedMessage[]
        throw second
      }
    }
    const row = rowFromAck(ack, frame, { from: live.identity.value, channel: channelNow })
    if (!row.msg_id) row.msg_id = String(frame.msg_id || '')
    if (row.msg_id && showHere) {
      messages.value = mergeLive(messages.value, row) as FeedMessage[]
      follow()
    }
    return row
  }

  async function createChannel(name: string, description = '') {
    const slug = channelSlug(name)
    if (!slug) throw new Error(i18n.t('sidebar.channel_name_required'))
    const row = await withSessionRetry(api, () => api.createChannel({ channel_id: slug, name, description }))
    const id = String(row.channel_id || slug)
    await loadChannels()
    await selectChannel(id)
    return { ...row, channel_id: id }
  }

  function repliesFor(taskId: string) {
    return topicReplies(messages.value, taskId)
  }

  return {
    channels,
    ordered,
    liveAt,
    dmAt,
    noteLive,
    addChannel,
    loadDmActivity,
    active,
    peer,
    messages,
    unread,
    loading,
    error,
    feed,
    newestFirst,
    hasOlder,
    loadingOlder,
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
    applyEdited,
    catchUp,
    send,
    createChannel,
    repliesFor,
  }
})
