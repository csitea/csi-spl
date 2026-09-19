import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { displayName } from '~/utils/channel-feed.mjs'
import { applyPresence, splitPeer } from '~/utils/live-follow.mjs'

export const useRosterStore = defineStore('roster', () => {
  const api = useSpoolApi()
  const live = useLive()
  const roster = ref<Record<string, string[]>>({})
  const online = ref<string[]>([])
  const me = ref({ id: 'HUM-1', box: 'box-wui' })

  const peers = computed(() => {
    const rows: { id: string, box: string, label: string, online: boolean }[] = []
    const listed = new Set<string>()
    for (const [box, agents] of Object.entries(roster.value)) {
      for (const id of agents) {
        if (id === me.value.id && box === me.value.box) continue
        const label = displayName(id, box)
        listed.add(label)
        rows.push({ id, box, label, online: online.value.includes(label) })
      }
    }
    /* 003 FR-028: humans (HUM-n@box-wui) are in no box roster; presence alone lists them */
    for (const label of online.value) {
      if (listed.has(label)) continue
      const { id, box } = splitPeer(label)
      if (!box || (id === me.value.id && box === me.value.box) || id === live.identity.value) continue
      rows.push({ id, box, label, online: true })
    }
    return rows.sort((a, b) => a.label.localeCompare(b.label))
  })

  /** wui-live-ws §3: one `presence` frame, last writer wins per peer. */
  function applyFrame(f: Record<string, unknown>) {
    online.value = applyPresence(online.value, f as { type?: string, peer?: string, status?: string })
  }
  live.onPresence(applyFrame)

  async function refresh() {
    const data = await api.listRoster() as {
      roster?: Record<string, string[]>
      online?: string[]
      me?: { id: string, box: string }
    }
    if (data.roster) roster.value = data.roster
    if (data.online) {
      /* the roster snapshot owns its boxes; presence-only peers (humans) survive it */
      const boxes = new Set(Object.keys(roster.value))
      const kept = online.value.filter((l) => !boxes.has(splitPeer(l).box))
      online.value = [...new Set([...data.online, ...kept])]
    }
    if (data.me) me.value = data.me
  }

  function isOnline(id: string, box?: string) {
    const label = box ? `${id}@${box}` : id
    return online.value.includes(label) || online.value.includes(id)
  }

  return { roster, online, me, peers, refresh, isOnline, applyFrame }
})
