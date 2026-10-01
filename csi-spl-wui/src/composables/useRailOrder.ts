// SPL-979: the person's left-rail order, one value for the rail and for
// Settings -> Behaviour -> "Left panel order". It is the `rail_order` session
// claim (kept on the hub), so a drop in either place redraws both at once.
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { applyRailOrder, parseRailOrder, pinRailOrder, type RailId } from '~/utils/rail-order.mjs'

export function useRailOrder() {
  const session = useSessionStore()
  const auth = useAuthClient()
  const order = computed<RailId[]>(() => parseRailOrder(session.claims?.rail_order))
  const custom = computed(() => Array.isArray(session.claims?.rail_order) && session.claims.rail_order.length > 0)
  const saving = ref(false)

  /** Store `next` (null = the default order). Resolves the save's outcome. */
  async function save(next: string[] | null) {
    if (session.state !== 'in') return { ok: false, value: null as string[] | null }
    saving.value = true
    try {
      return await applyRailOrder(next, {
        current: session.claims?.rail_order,
        apply: (o) => session.setRailOrder(o),
        save: (o) => auth.saveRailOrder(o),
      })
    } finally {
      saving.value = false
    }
  }

  /* CLE-77916: Archive stays last in a drag preview too */
  const normalize = (o: RailId[]) => pinRailOrder(o)

  return { order, custom, saving, save, normalize }
}
