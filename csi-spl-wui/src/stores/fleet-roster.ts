import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { fleetLoadReadable } from '~/utils/fleet-load.mjs'
import { normalizeFleetRoster } from '~/utils/fleet-roster.mjs'
import type { ForeignBox } from '~/utils/fleet-roster.mjs'

type FleetRosterApi = { getFleetRoster: () => Promise<unknown> }
type Seat = { workspace: string, workspaceName: string }

/* Spec 153 3.18 (SPL-4786): the other workspaces' own boxes and agents, for
   the operator workspace's Agents, Boxes and the agent card; read once per
   page load (load(true) reads again). Anyone the hub refuses (403) or a hub
   without the route reads as no rows: only the operator's lists grow. */
export const useFleetRosterStore = defineStore('fleet-roster', () => {
  const boxes = ref<ForeignBox[]>([])
  const alsoSeated = ref<Record<string, Seat[]>>({})
  /* idle | loading | ready | none (not the operator, or the read failed) */
  const state = ref<'idle' | 'loading' | 'ready' | 'none'>('idle')
  let pending: Promise<void> | null = null

  function load(again = false): Promise<void> {
    if (pending && !again) return pending
    state.value = 'loading'
    pending = (async () => {
      try {
        const me = await useAccessStore().ensure()
        if (!fleetLoadReadable(me)) { state.value = 'none'; return }
        const api = useSpoolApi() as unknown as FleetRosterApi
        const v = normalizeFleetRoster(await api.getFleetRoster())
        boxes.value = v.boxes
        alsoSeated.value = v.alsoSeated
        state.value = 'ready'
      } catch {
        boxes.value = []
        alsoSeated.value = {}
        state.value = 'none'
      }
    })()
    return pending
  }
  return { boxes, alsoSeated, state, load }
})
