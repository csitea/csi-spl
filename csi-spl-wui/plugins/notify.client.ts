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

  watch(
    () => [channel.active, channel.peer, route.path] as const,
    () => {
      const c = ctx()
      if (c.activeKey) notes.markRead(c.activeKey)
    },
    { immediate: true },
  )

  live.onMessage((m) => {
    notes.ingest([m], ctx(), { hydrate: false })
  })
})
