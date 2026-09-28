import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { applyPresence, mergeSnapshotOnline, peopleRows, withSessionRetry } from '~/utils/live-follow.mjs'
import { BROWSER_BOX } from '~/utils/view-api.mjs'

export const useRosterStore = defineStore('roster', () => {
  const api = useSpoolApi()
  const live = useLive()
  const roster = ref<Record<string, string[]>>({})
  const online = ref<string[]>([])
  /** view-v1 §4.1 owner:true - the business owner(s) #feedback offers to @. */
  const owners = ref<string[]>([])
  /** The mock tenant answers with its own `me`; live, the socket's welcome does. */
  const me = ref({ id: '', box: BROWSER_BOX })

  /**
   * Who the reader is, as the pane must know them. The socket's `welcome.as`
   * (wui-live-ws §3.2) is authoritative and arrives before any presence frame.
   *
   * this used to default to a literal `HUM-1` that a live session
   * never overwrote — `/v1/view/roster` carries no `me` — so on any tenant
   * whose member list holds a real HUM-1, that member would be taken for the
   * reader and hidden from everybody.
   */
  const selfId = computed(() => live.identity.value || me.value.id)

  /** Every peer the reader can see, the reader's own row marked `self`. */
  const people = computed(() => peopleRows(roster.value, online.value, selfId.value, me.value.box))
  /** The reader's own row, or null before the socket has said who we are. */
  const self = computed(() => people.value.find((p) => p.self) || null)
  /** Everyone but the reader: what the DM list and the @mention picker want. */
  const peers = computed(() => people.value.filter((p) => !p.self))

  /** wui-live-ws §3: one `presence` frame, last writer wins per peer. */
  function applyFrame(f: Record<string, unknown>) {
    online.value = applyPresence(online.value, f as { type?: string, peer?: string, status?: string })
  }
  live.onPresence(applyFrame)

  async function refresh() {
    const data = await withSessionRetry(api, () => api.listRoster()) as {
      roster?: Record<string, string[]>
      online?: string[]
      me?: { id: string, box: string }
      owners?: string[]
    }
    if (data.roster) roster.value = data.roster
    if (data.online) online.value = mergeSnapshotOnline(online.value, data.online, roster.value)
    if (data.me) me.value = data.me
    if (Array.isArray(data.owners)) owners.value = data.owners
  }

  function isOnline(id: string, box?: string) {
    const label = box ? `${id}@${box}` : id
    return online.value.includes(label) || online.value.includes(id)
  }

  return { roster, online, owners, me, self, people, peers, refresh, isOnline, applyFrame }
})
