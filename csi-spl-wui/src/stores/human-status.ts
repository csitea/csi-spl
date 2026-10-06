import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useRosterStore, type HumanStatus, type StatusLabel } from '~/stores/roster'

type Translate = (key: string, params?: Record<string, string>) => string
interface StatusController {
  apply(frame: unknown): void
  fill(humans: readonly object[], mock: boolean): void
  label(id: string, t: Translate): StatusLabel | null
}

/**
 * Spec 096: member id -> manual status (Busy / Unavailable), from the roster
 * read (humans[].status) and the `status` frame; an available member has no
 * entry. Nothing of it is in stores/roster.ts or the entry chunk: the store
 * reads the roster body itself (api.rosterView, which joins a roster request
 * already in flight), and on a reconnect it starts empty, because the hub's
 * welcome sends one `status` frame per live status right after it. Only the components that draw a
 * status use this store, so none of it rides the entry chunk, and the
 * machinery (utils/human-status.mjs statusController) loads with the first
 * status seen (027 initial-chunk budget). Reading `statusByPeer` first makes
 * a caller's computed re-run once the controller has filled it.
 */
export const useHumanStatusStore = defineStore('human-status', () => {
  const api = useSpoolApi()
  const roster = useRosterStore()
  const statusByPeer = ref<Record<string, HumanStatus>>({})
  let ctl: StatusController | null = null
  let loading: Promise<StatusController> | null = null
  const need = () => (loading ||= import('~/utils/human-status.mjs').then((m) => (ctl = m.statusController(statusByPeer) as StatusController)))

  /** spec 096 §7.4: one `status` frame, last writer wins per member; the
      picker applies the reader's own at once, before the hub's frame */
  async function applyStatus(f: Record<string, unknown>) {
    (await need()).apply(f)
  }
  const live = useLive()
  live.onPresence((f) => { if (f.type === 'status') void applyStatus(f) })

  /* the roster read's humans[]: their statuses replace the map */
  function fill(humans: Array<{ human_id?: string, status?: unknown }>) {
    if (api.mock || humans.some((h) => h.status)) void need().then((c) => c.fill(humans, api.mock))
  }
  if (api.mock) {
    /* the lde mock has no hub: its members, with the statuses it keeps in localStorage */
    watch(() => roster.humansDetail, (d) => fill(Object.keys(d).map((human_id) => ({ human_id }))), { immediate: true })
  } else if (import.meta.client) {
    void api.rosterView().then((body) => fill(((body as { humans?: [] } | null)?.humans) || []), () => {})
    live.onReconnected(() => { statusByPeer.value = {} })
  }

  /** a member's status in words, for a dot's label and the text beside a name */
  const statusLabel = (id: string, t: Translate) => (statusByPeer.value && ctl ? ctl.label(id, t) : null)

  return { statusByPeer, statusLabel, applyStatus }
})
