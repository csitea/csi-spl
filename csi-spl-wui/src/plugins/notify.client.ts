import { useChannelStore } from '~/stores/channel'
import { useNotificationStore } from '~/stores/notification'
import { useSessionStore } from '~/stores/session'
import { useLive } from '~/composables/useLive'
import type { useLiveFeed } from '~/stores/live'
import type { useTopicStore } from '~/stores/topic'
import { normalizeChannel } from '~/utils/notify.mjs'

function activeKey(path: string, peer: string | null, channel: string | null) {
  const p = String(path || '')
  if (p.startsWith('/dm/')) return `dm:${decodeURIComponent(p.slice(4))}`
  if (p.startsWith('/channel/')) return `ch:${normalizeChannel(p.slice('/channel/'.length))}`
  if (p === '/lobby' || p === '/') return 'ch:lobby'
  if (peer) return `dm:${peer}`
  if (channel) return `ch:${normalizeChannel(channel)}`
  return ''
}

/* The topic and live-feed stores load lazily: a static import put both into
   the initial chunk (ci_initial_gzip_kb 154.2 -> 158.4, over the 027 budget).
   The default layout imports them too, so they are in memory by the time a
   feed renders; until then no thread is open and no feed is held. */
const lazy: { useLiveFeed?: typeof useLiveFeed; useTopicStore?: typeof useTopicStore } = {}

/** HUM-24 (t1 cd9b0f47): the threads on screen - a reply into any other
 *  topic of the open feed is off screen and signals (offScreenReply). */
function openTopics(path: string) {
  const out: string[] = []
  if (lazy.useTopicStore && lazy.useLiveFeed) {
    const topic = lazy.useTopicStore()
    /* a channel's thread pane (stores/topic), the Topics view's (the pane feed) */
    out.push(topic.open ? String(topic.parentTaskId || '') : '', String(lazy.useLiveFeed('pane').taskId || ''))
  }
  if (path.startsWith('/t/')) out.push(decodeURIComponent(path.slice(3).split('/')[0]))
  /* the lobby room's own lines are its middle pane */
  if (lazy.useLiveFeed && (path.startsWith('/t/') || path === '/lobby' || path === '/')) out.push(String(lazy.useLiveFeed('main').taskId || ''))
  return out.filter(Boolean)
}

/** What the notification store needs to know about the page the reader is on. */
function pageCtx(channel: ReturnType<typeof useChannelStore>, selfId: string, path: string, stores: Record<string, { statusByPeer?: Record<string, never> }>) {
  const peer = channel.peer
  const name = channel.active
  return {
    selfId,
    /* spec 096 T005: the reader's own status, read from the lazy status
       store's state by id, so the entry chunk imports none of it (027) */
    status: stores['human-status']?.statusByPeer?.[selfId.split('@')[0]!],
    activeKey: activeKey(path, peer, name),
    channel: name || (path === '/lobby' ? 'lobby' : ''),
    peer,
    isDm: Boolean(peer) || path.startsWith('/dm/'),
    /* the lobby's topics live in the main feed store (pages/lobby), a channel's in the channel store */
    feed: [...channel.messages, ...(lazy.useLiveFeed ? lazy.useLiveFeed('main').messages : [])],
    openTopics: openTopics(path),
  }
}

/**
 * HUM-24 round 2: the catch-up read after a reconnect pings what the socket
 * missed (spool-live reloads channels + DMs on the same signal); a first load
 * never does. take() reads a kind's flag once and clears it.
 */
function catchUpAfterReconnect(live: ReturnType<typeof useLive>) {
  const pending = { channels: false, dms: false }
  live.onReconnected(() => {
    pending.channels = true
    pending.dms = true
  })
  return {
    take(kind: keyof typeof pending) {
      const v = pending[kind]
      pending[kind] = false
      return v
    },
  }
}

export default defineNuxtPlugin(() => {
  const notes = useNotificationStore()
  const channel = useChannelStore()
  const session = useSessionStore()
  const live = useLive()
  const route = useRoute()
  const pinia = usePinia()
  notes.hydrate()
  void import('~/stores/live').then((m) => (lazy.useLiveFeed = m.useLiveFeed))
  void import('~/stores/topic').then((m) => (lazy.useTopicStore = m.useTopicStore))

  const ctx = () => pageCtx(channel, String((session.claims && session.claims.hum) || live.identity.value || ''), String(route.path || ''), pinia.state.value)

  watch(
    () => channel.messages.map((m) => m.msg_id).join('\n'),
    () => {
      notes.ingest(channel.messages, ctx())
    },
  )

  /** The open channel's hub row: reading it keeps the hub cursor for the next read=. */
  function markActive() {
    const c = ctx()
    if (!c.activeKey) return
    /* CLE-77804: freeze the New-messages divider boundary at the real open,
       before markChannelRead/markRead advances the cursor past the unread. */
    notes.enterFeed(c.activeKey)
    const id = c.activeKey.startsWith('ch:') ? c.activeKey.slice(3) : ''
    const row = id ? channel.channels.find((r) => r.channel_id === id) : undefined
    if (row && row.last_cursor) notes.markChannelRead(c.activeKey, row)
    else notes.markRead(c.activeKey)
  }

  watch(() => [channel.active, channel.peer, route.path] as const, markActive, { immediate: true })

  const catchUp = catchUpAfterReconnect(live)

  /* hub unread per channel (channels-v1 §5.2), counted against our read= cursors */
  watch(
    () => channel.channels,
    (rows) => {
      notes.applyChannels(rows, ctx().activeKey, { catchUp: catchUp.take('channels') })
      markActive()
    },
  )

  /* the DM twin: DM badges are reseeded here from the ?dm=true rows
     loadDmActivity fetched (plugins/spool-live.client.ts) with the hub's
     per-peer counts against our dm_read= cursors, on first paint and every
     reconnect. */
  watch(
    () => channel.dmSeed,
    (topics) => {
      const page = ctx()
      notes.applyDms(topics, page.selfId, page.activeKey, { catchUp: catchUp.take('dms') })
    },
    { immediate: true },
  )

  /*
   * A live frame is keyed by ITS OWN channel, not the open page: a #alerts
   * message escalates as alerts even while a DM is open (FR-014).
   */
  live.onMessage((m) => {
    const page = ctx()
    notes.countDmLive(m, page.selfId)
    notes.ingest([m], { selfId: page.selfId, activeKey: page.activeKey, feed: page.feed, openTopics: page.openTopics, status: page.status }, { hydrate: false })
  })
})
