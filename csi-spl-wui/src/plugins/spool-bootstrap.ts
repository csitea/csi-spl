// The shell's first reads. Both the channel list and the roster need a member
// session, so firing them on every page load answered 401 view_door twice —
// on /login too, where there is no shell and nothing to fill.
//
// So: wait for the session store to say 'in' (ChannelSidebar and the login
// page own the probe; a native sign-in adopts the claims into the same store),
// then read both, once. The mock tenant has no hub and no session: it hydrates
// straight away, as it did before.
import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { createShellBootstrap } from '~/utils/shell-bootstrap.mjs'

export default defineNuxtPlugin(() => {
  if (!import.meta.client) return
  const channel = useChannelStore()
  const roster = useRosterStore()
  const boot = createShellBootstrap({
    loadChannels: () => channel.loadChannels(),
    refreshRoster: () => roster.refresh(),
  })
  if (useSpoolApi().mock) {
    void boot.start()
    return
  }
  const session = useSessionStore()
  watch(() => session.state, (state) => { void boot.onSession(String(state)) }, { immediate: true })
})
