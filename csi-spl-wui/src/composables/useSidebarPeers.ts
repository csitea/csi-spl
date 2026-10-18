/*
 * ChannelSidebar's Direct messages list (r13-04): the peers in activity order,
 * pinned on top, and what a row's menu does to one (pin, block, mute, remove,
 * hide from this list).
 */
import { computed, ref, type ComputedRef } from 'vue'
import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import type { useSpoolApi } from '~/composables/useSpoolApi'
import type { useLive } from '~/composables/useLive'
import type { useFlowKeys } from '~/composables/useFlowBadge'
import { withDmPeers } from '~/utils/live-follow.mjs'
import { orderPeers } from '~/utils/channel-feed.mjs'
import { flowDmPeers } from '~/utils/flow-keys.mjs'
import { hidePeer, peerHidden, pinRows, saveHiddenPeers } from '~/utils/sidebar-row-menu.mjs'
import { useUnreadOrder } from '~/composables/useUnreadOrder'

export function useSidebarPeers(api: ReturnType<typeof useSpoolApi>, live: ReturnType<typeof useLive>, acting: ComputedRef<boolean>, flowKeys: ReturnType<typeof useFlowKeys>, unreadOf: (key: string) => number) {
  const channel = useChannelStore()
  const roster = useRosterStore()
  /* newest first here too - the peer we last exchanged a DM with on top */
  const hiddenPeers = ref<Record<string, true>>({})
  /* "Remove from list": this browser only, until a newer DM (sidebar-row-menu.mjs) */
  const listHidden = ref<Record<string, string>>({})
  const blockedPeers = ref<Record<string, true>>({})
  const mutedPeers = ref<Record<string, true>>({})
  /* index 0 is the top. A drag replaces the whole list: that order is pinned,
     and a person who appears later sorts after it, in the usual activity order. */
  const pinnedPeers = ref<string[]>([])
  /* SPL-2506: peers with unread at the edge new posts go to, the most at the very edge; ties: the newest DM */
  const unreadOrder = useUnreadOrder()
  const peers = computed(() => (acting.value ? [] : unreadOrder.order(pinRows(
    /* owner (t1 77540e6f): a peer with unread lines always has a row, even one
       no roster lists any more (a retired agent), so the number can be read */
    withDmPeers(orderPeers(withDmPeers(roster.peers, channel.dmAt, roster.self ? roster.self.id : live.identity.value), channel.dmAt),
      flowDmPeers(flowKeys.value), roster.self ? roster.self.id : live.identity.value)
      .filter((p) => unreadOf('dm:' + p.label) > 0 || (!hiddenPeers.value[p.label] && !peerHidden(listHidden.value, p.label, channel.dmAt[p.label]))),
    pinnedPeers.value,
  ), (p) => unreadOf('dm:' + p.label), (p) => channel.dmAt[p.label] || '')))
  function toggleOrder(order: string[], key: string) {
    return order.includes(key) ? order.filter((l) => l !== key) : [key, ...order.filter((l) => l !== key)]
  }
  function togglePin(label: string) {
    pinnedPeers.value = toggleOrder(pinnedPeers.value, label)
  }

  function togglePeer(which: 'block' | 'mute', label: string) {
    const bag = which === 'block' ? blockedPeers : mutedPeers
    const next = { ...bag.value }
    if (next[label]) delete next[label]
    else next[label] = true
    bag.value = next
  }

  /* A human is a tenant member: DELETE /v1/members/{id}. A bot is not, so the
     row leaves this pane for the session and the hub membership is untouched. */
  async function removePeer(p: { id?: string, label: string }) {
    const id = String(p.id || '')
    if (/^HUM-\d+$/.test(id) && !api.mock) {
      try {
        await api.removeMember(id)
      } catch {
        return
      }
      void roster.refresh()
    }
    hiddenPeers.value = { ...hiddenPeers.value, [p.label]: true }
    pinnedPeers.value = pinnedPeers.value.filter((l) => l !== p.label)
  }
  function hideFromList(p: { label: string }) {
    listHidden.value = saveHiddenPeers(hidePeer(listHidden.value, p.label, channel.dmAt[p.label] || ''))
    pinnedPeers.value = pinnedPeers.value.filter((l) => l !== p.label)
  }
  return { listHidden, blockedPeers, mutedPeers, pinnedPeers, peers, togglePin, togglePeer, removePeer, hideFromList }
}
