import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { displayName } from '~/utils/channel-feed.mjs'

export const useRosterStore = defineStore('roster', () => {
  const api = useSpoolApi()
  const roster = ref<Record<string, string[]>>({})
  const online = ref<string[]>([])
  const me = ref({ id: 'HUM-1', box: 'box-wui' })

  const peers = computed(() => {
    const rows: { id: string, box: string, label: string, online: boolean }[] = []
    for (const [box, agents] of Object.entries(roster.value)) {
      for (const id of agents) {
        if (id === me.value.id && box === me.value.box) continue
        const label = displayName(id, box)
        rows.push({ id, box, label, online: online.value.includes(label) })
      }
    }
    return rows.sort((a, b) => a.label.localeCompare(b.label))
  })

  async function refresh() {
    const data = await api.listRoster() as {
      roster?: Record<string, string[]>
      online?: string[]
      me?: { id: string, box: string }
    }
    if (data.roster) roster.value = data.roster
    if (data.online) online.value = data.online
    if (data.me) me.value = data.me
  }

  function isOnline(id: string, box?: string) {
    const label = box ? `${id}@${box}` : id
    return online.value.includes(label) || online.value.includes(id)
  }

  return { roster, online, me, peers, refresh, isOnline }
})
