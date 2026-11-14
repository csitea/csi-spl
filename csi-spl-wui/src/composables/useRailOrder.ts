// SPL-979: the person's left-rail order, one value for the rail and for
// Settings -> Behaviour -> "Left panel order". It is the `rail_order` session
// claim (kept on the hub), so a drop in either place redraws both at once.
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { useAddToNote } from '~/composables/useAddToNote'
import { useExpensesReader } from '~/composables/useExpensesReader'
import { useCostWriter } from '~/composables/useOperatorReader'
import { perfWhenIdle } from '~/utils/perf-idle.mjs'
import { applyRailOrder, parseRailOrder, pinRailOrder, railOrderDrawn, type RailId } from '~/utils/rail-order'

export function useRailOrder() {
  const session = useSessionStore()
  const auth = useAuthClient()
  const notes = useAddToNote()
  const expensesReader = useExpensesReader()
  /* SPL-5433: a costs.write member of the operator workspace opens Expenses too */
  const costWriter = useCostWriter()
  const order = computed<RailId[]>(() => railOrderDrawn(parseRailOrder(session.claims?.rail_order), notes.offered.value, expensesReader.value || costWriter.value))
  const custom = computed(() => Array.isArray(session.claims?.rail_order) && session.claims.rail_order.length > 0)
  const saving = ref(false)

  /* spec 155 section 6: the read that hides the Notes tab on notes_off, in an
     idle slot once signed in, so the first paint pays nothing for it */
  if (import.meta.client) {
    watch(() => session.state, (s) => { if (s === 'in') perfWhenIdle(() => notes.probe()) }, { immediate: true })
  }

  /** Store `next` (null = the default order). Resolves the save's outcome. */
  async function save(next: string[] | null) {
    if (session.state !== 'in') return { ok: false, value: null as string[] | null }
    saving.value = true
    try {
      /* a drag while Notes or Expenses is hidden: parseRailOrder puts it back for the hub */
      return await applyRailOrder(next && parseRailOrder(next), {
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
