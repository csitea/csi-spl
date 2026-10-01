import { useChannelStore } from '~/stores/channel'
import { useNotificationStore } from '~/stores/notification'
import { useSessionStore } from '~/stores/session'
import { useLive } from '~/composables/useLive'
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

export default defineNuxtPlugin(() => {
  const notes = useNotificationStore()
  const channel = useChannelStore()
  const session = useSessionStore()
  const live = useLive()
  const route = useRoute()
  notes.hydrate()

  function ctx() {
    const peer = channel.peer
    const name = channel.active
    const path = String(route.path || '')
    return {
      selfId: (session.claims && session.claims.hum) || live.identity.value || '',
      activeKey: activeKey(path, peer, name),
      channel: name || (path === '/lobby' ? 'lobby' : ''),
      peer,
      isDm: Boolean(peer) || path.startsWith('/dm/'),
    }
  }

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

  /* hub unread per channel (channels-v1 §5.2), counted against our read= cursors */
  watch(
    () => channel.channels,
    (rows) => {
      notes.applyChannels(rows, ctx().activeKey)
      markActive()
    },
  )

  /* the DM twin: the hub counts unread for channels only, so DM badges are
     recomputed here from our cursors + the ?dm=true rows loadDmActivity fetched
     (plugins/spool-live.client.ts), on first paint and every reconnect. */
  watch(
    () => channel.dmSeed,
    (topics) => {
      const page = ctx()
      notes.applyDms(topics, page.selfId, page.activeKey)
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
    notes.ingest([m], { selfId: page.selfId, activeKey: page.activeKey }, { hydrate: false })
  })
})
