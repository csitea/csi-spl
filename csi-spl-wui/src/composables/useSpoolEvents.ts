import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'

/**
 * Channel / DM tail. Live mode rides the hub WUI socket (003 wui-live-ws):
 * each message frame is merged into the open feed, and a reconnect re-reads
 * the first page once and merges it by msg_id (013 US7 FR-015). Only the mock tenant (no socket) polls.
 */
export function useSpoolEvents() {
  const channel = useChannelStore()
  const roster = useRosterStore()
  const api = useSpoolApi()
  let timer: ReturnType<typeof setInterval> | null = null
  let off: (() => unknown) | null = null
  let offReconnect: (() => unknown) | null = null

  function stop() {
    if (timer) {
      clearInterval(timer)
      timer = null
    }
    if (off) off()
    off = null
    if (offReconnect) offReconnect()
    offReconnect = null
  }

  function start() {
    stop()
    if (!import.meta.client) return
    if (api.mock) {
      timer = setInterval(() => {
        void channel.refresh()
        void roster.refresh()
      }, 4000)
      return
    }
    const live = useLive()
    live.ensure()
    off = live.onMessage((m) => channel.ingestLive(m))
    offReconnect = live.onReconnected(() => {
      void channel.catchUp()
      void channel.loadChannels()
      void roster.refresh()
    })
  }

  onUnmounted(stop)
  return { start, stop }
}
