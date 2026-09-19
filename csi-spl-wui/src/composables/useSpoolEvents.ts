import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'

/**
 * Live tail. Box WS `/v1/ws` is Ed25519 and not for the browser.
 * Until the hub grows a session socket, poll the active channel.
 */
export function useSpoolEvents() {
  const channel = useChannelStore()
  const roster = useRosterStore()
  let timer: ReturnType<typeof setInterval> | null = null

  function stop() {
    if (timer) {
      clearInterval(timer)
      timer = null
    }
  }

  function start() {
    stop()
    if (!import.meta.client) return
    timer = setInterval(() => {
      void channel.refresh()
      void roster.refresh()
    }, 4000)
  }

  onUnmounted(stop)
  return { start, stop }
}
