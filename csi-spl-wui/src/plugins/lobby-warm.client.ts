// start /lobby's first two reads when the session says 'in', not
// when the page has mounted (utils/lobby-warm.mjs says why and how nothing is
// lost). Only on a load that lands on /lobby, only with a lobby id in the
// build, never in the mock tenant.
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { WINDOW } from '~/utils/feed-window.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { isLobbyPath, startLobbyWarm } from '~/utils/lobby-warm.mjs'

export default defineNuxtPlugin(() => {
  if (!import.meta.client) return
  const api = useSpoolApi()
  if (api.mock || !isLobbyPath(window.location.pathname)) return
  const live = useLive()
  const id = live.lobbyTaskId.value
  if (!id) return
  const session = useSessionStore()
  let started = false
  watch(() => session.state, (state) => {
    if (started || String(state) !== 'in') return
    started = true
    startLobbyWarm({
      id,
      room: () => withSessionRetry(api, () => api.getTopic(id, { order: 'desc', limit: WINDOW })),
      topics: () => withSessionRetry(api, () => api.listMessages({ channel: 'lobby', limit: 50 })),
      onMessage: live.onMessage,
    })
  }, { immediate: true })
})
