import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { createShellBootstrap, shouldOpenHubSocket, startHubSocket, stopHubSocket } from '~/utils/shell-bootstrap.mjs'

/**
 * Channel / DM tail. Live mode rides the hub WUI socket (003 wui-live-ws):
 * each message frame is merged into the open feed, and a reconnect re-reads
 * the first page once and merges it by msg_id (013 US7 FR-015). Only the mock tenant (no socket) polls.
 *
 * Channels + roster go through createShellBootstrap (the same gate the plugin
 * uses): signed out they do not fire, the mock tenant hydrates immediately,
 * and a member session reads each once for the life of this tail.
 *
 * The socket itself is gated the same way (W5): start() on a signed-out
 * /channel or /dm does not call live.ensure(); a sign-in flips the session
 * store and the watch brings the socket up with no reload; a sign-out
 * closes it so the client does not retry with backoff.
 */
export function useSpoolEvents() {
  const channel = useChannelStore()
  const roster = useRosterStore()
  const api = useSpoolApi()
  const session = useSessionStore()
  const boot = createShellBootstrap({
    loadChannels: () => channel.loadChannels(),
    refreshRoster: () => roster.refresh(),
  })
  let timer: ReturnType<typeof setInterval> | null = null
  let off: (() => unknown) | null = null
  let offReconnect: (() => unknown) | null = null
  let offSession: (() => void) | null = null

  function stop() {
    if (timer) {
      clearInterval(timer)
      timer = null
    }
    if (off) off()
    off = null
    if (offReconnect) offReconnect()
    offReconnect = null
    if (offSession) offSession()
    offSession = null
  }

  function start() {
    stop()
    if (!import.meta.client) return
    if (api.mock) {
      timer = setInterval(() => {
        void channel.refresh()
        void roster.refresh()
      }, 4000)
      void boot.start()
      return
    }
    const live = useLive()
    function attach() {
      startHubSocket(live)
      if (!off) off = live.onMessage((m) => channel.ingestLive(m))
      if (!offReconnect) offReconnect = live.onReconnected(() => {
        void channel.catchUp()
        void boot.onSession(String(session.state))
      })
    }
    function detach() {
      if (off) off()
      off = null
      if (offReconnect) offReconnect()
      offReconnect = null
      stopHubSocket(live)
    }
    offSession = watch(() => session.state, (st) => {
      if (shouldOpenHubSocket(st)) attach()
      else detach()
    }, { immediate: true })
  }

  onUnmounted(stop)
  return { start, stop }
}
