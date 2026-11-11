/**
 * SPL-5312 (spec 143 costs-redesign.md 3.9): the month answers of the Costs
 * header's period, read once per label page. A month is
 * GET /v1/tenant/costs?month=YYYY-MM (the current month: no month, the
 * hub's "so far"); the year to date reads January to now, one call each, in
 * parallel. The hub scopes every answer to the reader (the estate for the
 * operator admin, else the workspace); utils/costs-labels.mjs makes the rows.
 */
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { costsCurrency, costsCurrencyOptions, costsMonthOptions, costsPeriod, costsPeriodMonths } from '~/utils/reporting-costs.mjs'
import { COSTS_READ, costMonthOf } from '~/utils/tenant-costs.mjs'

type CostsApi = { getTenantCosts: (month?: string, secondCurrency?: string) => Promise<unknown> }
export type CostMonth = ReturnType<typeof costMonthOf>

export function useCostsPeriod() {
  const route = useRoute()
  const session = useSessionStore()
  /* the reader's second currency: the hub converts by the session's, the mock is handed it */
  const pick = computed(() => String(session.claims?.second_currency || ''))
  const current = costsMonthOptions(new Date())[0]
  const period = computed(() => costsPeriod(route.query.month, new Date()) || current)
  const months = computed(() => costsPeriodMonths(period.value, new Date()))
  const currency = computed(() => costsCurrency(route.query.currency, costsCurrencyOptions(pick.value)))
  const views = ref<CostMonth[]>([])
  const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
  const forbiddenPerm = ref(COSTS_READ)

  let seq = 0
  async function load() {
    const mine = ++seq
    state.value = 'loading'
    const api = useSpoolApi() as unknown as CostsApi
    try {
      const bodies = await Promise.all(months.value.map((m) => api.getTenantCosts(m === current ? '' : m, pick.value)))
      if (mine !== seq) return
      views.value = bodies.map((b) => costMonthOf(b))
      state.value = 'ok'
    } catch (e) {
      if (mine !== seq) return
      views.value = []
      const err = e as { status?: number, permission?: string }
      forbiddenPerm.value = err?.permission || COSTS_READ
      state.value = err?.status === 403 ? 'forbidden' : 'error'
    }
  }

  onMounted(() => {
    watch(() => [months.value.join(','), pick.value], () => { void load() }, { immediate: true })
  })
  return { period, months, currency, current, pick, views, state, forbiddenPerm }
}
