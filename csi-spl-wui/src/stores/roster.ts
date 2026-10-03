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
  /** CLE-77794: per-member detail for the People info card (view-v1 §4.1
   *  humans[]): owner flag, free-text interests and last_seen, keyed HUM-*. */
  const humansDetail = ref<Record<string, HumanDetail>>({})
  /** CLE-77794: per-box detail for the Agents info card (view-v1 §4.1
   *  boxes[]): online + last_hello_at, keyed by box_id. */
  const boxes = ref<Record<string, BoxDetail>>({})
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
      humans?: Array<HumanDetail & { human_id?: string }>
      boxes?: Array<BoxDetail & { box_id?: string }>
    }
    if (data.roster) roster.value = data.roster
    if (data.online) online.value = mergeSnapshotOnline(online.value, data.online, roster.value)
    if (data.me) me.value = data.me
    if (Array.isArray(data.owners)) owners.value = data.owners
    if (Array.isArray(data.humans)) {
      const byId: Record<string, HumanDetail> = {}
      for (const h of data.humans) {
        const id = String(h?.human_id || '')
        if (id) byId[id] = { owner: Boolean(h.owner), interests: String(h.interests || ''), last_seen: String(h.last_seen || '') }
      }
      humansDetail.value = byId
    }
    if (Array.isArray(data.boxes)) {
      const byBox: Record<string, BoxDetail> = {}
      for (const b of data.boxes) {
        const id = String(b?.box_id || '')
        if (id) byBox[id] = { online: Boolean(b.online), last_hello_at: String(b.last_hello_at || ''), seated_at: { ...(b.seated_at || {}) } }
      }
      boxes.value = byBox
    }
  }

  function isOnline(id: string, box?: string) {
    const label = box ? `${id}@${box}` : id
    return online.value.includes(label) || online.value.includes(id)
  }

  return { roster, online, owners, humansDetail, boxes, me, self, people, peers, refresh, isOnline, applyFrame }
})

/** view-v1 §4.1 humans[] detail the People card reads (CLE-77794). */
export interface HumanDetail {
  owner: boolean
  /** humans.interests (rdb 0086), "" when none. */
  interests: string
  /** tenant_memberships.last_active_at (RFC3339), "" when never. */
  last_seen: string
}

/** view-v1 §4.1 boxes[] detail the Agents card reads (CLE-77794). */
export interface BoxDetail {
  online: boolean
  /** boxes.last_hello_at (RFC3339), "" when the box never announced. */
  last_hello_at: string
  /** Spec 061 3.6 (rdb 0107): agent id -> when its current holder was seated
   *  (RFC3339). An id with no entry was seated before the hub recorded seats. */
  seated_at?: Record<string, string>
}
