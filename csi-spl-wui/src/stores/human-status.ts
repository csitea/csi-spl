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
 * read (humans[].status, kept raw by stores/roster.ts) and the `status`
 * frame; an available member has no entry. Only the components that draw a
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
  useLive().onPresence((f) => { if (f.type === 'status') void applyStatus(f) })

  /* the roster read's humans[]: their statuses replace the map */
  watch(() => roster.humansDetail, (detail) => {
    const humans = Object.entries(detail).map(([human_id, d]) => ({ human_id, status: d.status }))
    if (api.mock || humans.some((h) => h.status)) void need().then((c) => c.fill(humans, api.mock))
    else statusByPeer.value = {}
  }, { immediate: true })

  /** a member's status in words, for a dot's label and the text beside a name */
  const statusLabel = (id: string, t: Translate) => (statusByPeer.value && ctl ? ctl.label(id, t) : null)

  return { statusByPeer, statusLabel, applyStatus }
})
