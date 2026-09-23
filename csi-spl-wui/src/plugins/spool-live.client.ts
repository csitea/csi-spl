// spool-live.client.ts — CLE-3425: the tab-wide live follow.
//
// The owner's order is newest first EVERYWHERE, popping to the top in real time
// "without the user having to refresh the page". Until now the socket followed
// only what the OPEN view needed: the task ids on screen, the open channel, the
// open DM peer, and the whole tenant (`all`) but only while `/` was open. So a
// message in a channel nobody had open reached this tab not at all — the sidebar
// order, and the unread badge of every other channel, moved only on a reload or
// a reconnect.
//
// This plugin holds ONE `all` follow for the life of the tab (the hub's `wants`
// rule already limits DMs to the ones we are party to, wui.go), and feeds the
// per-channel / per-peer "last activity" the sidebar orders by. `all` is
// ref-counted in the live client, so the topic list on `/` taking its own
// follow and dropping it again does not take this one down.
//
// Gated on a member session, the same way the shell's other reads are (W4,
// CLE-55): signed out the hub answers 401 view_door to the DM read and the
// socket has no door either, so nothing here goes out until the session store
// says 'in'. The probe is owned by the shell and by the login page, and a
// sign-in flips the same store, so a human who signs in gets the follow with no
// reload. The mock tenant has no socket at all.
//
// Client-only: there is no socket on the server, and nothing here may be baked
// into a prerendered page.
import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'

export default defineNuxtPlugin(() => {
  if (!import.meta.client) return
  const api = useSpoolApi()
  if (api.mock) return // the mock tenant has no socket; its stores poll
  const channel = useChannelStore()
  const roster = useRosterStore()
  const live = useLive()
  let started = false

  /** The follow itself: one socket, one `all`, one first read. Once per tab. */
  function start() {
    if (started) return
    const client = live.ensure()
    if (!client) return
    started = true
    client.subscribeAll()
    void channel.loadDmActivity(live.identity.value)

    live.onMessage((m) => channel.noteLive(m, live.identity.value))
    live.onChannel((f) => channel.addChannel(f))
    live.onReconnected(() => {
      /* whatever the socket missed while it was down (wui-live-ws §7) */
      void channel.loadChannels()
      void channel.loadDmActivity(live.identity.value)
      void roster.refresh()
    })
  }

  const session = useSessionStore()
  watch(() => session.state, (state) => { if (String(state) === 'in') start() }, { immediate: true })
})
