<!-- Spec 123 5 + 5.2 (SPL-2056, owner HUM-10, t1 dbf2f39b, msgs 6cab186b /
     a54b9e74; spec owner words 45f8cb69: "a page which also has a pie chart,
     but a simple table split down on what everything costs"): Monitoring ->
     Costs. One month of GET /v1/tenant/costs: a month picker (the current
     month "so far", earlier months, never a future one), the table (one row
     per part, USD + EUR, % of the month, the list-price equivalent, the
     by-hand mark, a total row), "n of N days complete" per source, and the
     pie (MonitoringCostsPie, this route's own chunk). Honest empties: a
     source with no money yet is named, and no money at all draws no pie.
     costs.read is the hub's: its 403 shows here naming the permission.
     Not here yet: the hand-entry form (no hub API) and the token gap view.
     Spec 123 5.4 (SPL-2199, owner msg 44fef397): one more column, each part
     in the reader's second currency (Settings -> Appearance, EUR unless
     picked), its title the rate and the rate's date; no rate is a dash
     saying so, never a guess. A new pick reloads the month. -->
<template>
  <div class="monitoring-costs" data-test="costs-page">
    <div class="costs-head">
      <label class="costs-month">
        <span>{{ t('monitoring.costs.month') }}</span>
        <select v-model="month" data-test="costs-month">
          <option v-for="(m, i) in months" :key="m" :value="m">{{ i === 0 ? t('monitoring.costs.month_so_far', { month: m }) : m }}</option>
        </select>
      </label>
      <span v-if="view && view.status === 'so_far'" class="costs-so-far" data-test="costs-so-far">{{ t('monitoring.costs.so_far', { n: view.daysEnded, total: view.days }) }}</span>
      <span v-if="view" class="muted" data-test="costs-scope">{{ t(view.scope === 'estate' ? 'monitoring.costs.scope_estate' : 'monitoring.costs.scope_workspace') }}</span>
    </div>

    <p v-if="state === 'loading'" class="muted" data-test="costs-loading">{{ t('monitoring.costs.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="costs-forbidden" data-test="costs-forbidden">{{ t('monitoring.costs.forbidden', { perm: forbiddenPerm }) }}</p>
    <p v-else-if="state === 'error'" class="costs-error" data-test="costs-error">{{ t('monitoring.costs.error') }}</p>

    <template v-else-if="view">
      <ul v-if="empties.length" class="costs-empties" data-test="costs-empties">
        <li v-for="s in empties" :key="s" data-test="costs-empty-source" :data-source="s">{{ t('monitoring.costs.empty_source', { source: sourceLabel(s) }) }}</li>
      </ul>

      <MonitoringCostsPie v-if="slices.length" :label="t('monitoring.costs.pie_label')" :slices="slices" />
      <p v-else class="muted" data-test="costs-no-pie">{{ t('monitoring.costs.no_pie') }}</p>

      <div class="costs-table-wrap">
        <table class="costs-table" data-test="costs-table">
          <thead>
            <tr>
              <th scope="col">{{ t('monitoring.costs.col_part') }}</th>
              <th scope="col" class="num">USD</th>
              <th scope="col" class="num">EUR</th>
              <th scope="col" class="num" data-test="costs-second-head">{{ secondHead }}</th>
              <th scope="col" class="num">{{ t('monitoring.costs.col_pct') }}</th>
              <th scope="col" class="num">{{ t('monitoring.costs.col_list') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="p in view.parts" :key="partKey(p)" data-test="costs-row" :data-source="p.source">
              <td>
                <span class="costs-part">{{ sourceLabel(p.source) }} · {{ p.projectOrVendor || '-' }}</span>
                <span v-if="p.hand" class="costs-hand" data-test="costs-hand">{{ t('monitoring.costs.hand') }}</span>
                <span class="costs-kind muted">{{ p.kind }}<template v-if="units(p)"> · {{ units(p) }}</template><template v-if="p.origin === 'estimate'"> · {{ t('monitoring.costs.estimate') }}</template></span>
              </td>
              <td class="num" data-label="USD">{{ money(p.usdMicros, 'USD') }}</td>
              <td class="num" data-label="EUR">{{ money(p.eurMicros, 'EUR') }}</td>
              <td class="num" :data-label="secondHead" data-test="costs-second" :data-none="second(p).none ? '1' : '0'" :title="second(p).title">{{ second(p).text }}</td>
              <td class="num" :data-label="t('monitoring.costs.col_pct')">{{ p.pct === null ? '' : p.pct + ' %' }}</td>
              <td class="num" :data-label="t('monitoring.costs.col_list')">{{ p.listValueMicros ? money(p.listValueMicros, 'USD') : '' }}</td>
            </tr>
            <tr v-if="view.scope === 'estate'" class="costs-not-tracked" data-test="costs-not-tracked">
              <td>{{ t('monitoring.costs.outside_gcp') }}</td>
              <td colspan="5" class="muted">{{ t('monitoring.costs.not_tracked') }}</td>
            </tr>
            <tr v-if="view.parts.length === 0">
              <td colspan="6" class="muted" data-test="costs-no-rows">{{ t('monitoring.costs.no_rows') }}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr class="costs-total" data-test="costs-total">
              <th scope="row">{{ t('monitoring.costs.total') }}</th>
              <td class="num" data-label="USD" data-test="costs-total-usd">{{ money(view.total.usdMicros, 'USD') }}</td>
              <td class="num" data-label="EUR" data-test="costs-total-eur">{{ money(view.total.eurMicros, 'EUR') }}</td>
              <td class="num" :data-label="secondHead" data-test="costs-total-second" :title="second(view.total).title">{{ second(view.total).text }}</td>
              <td class="num" :data-label="t('monitoring.costs.col_pct')">{{ view.total.usdMicros > 0 ? '100 %' : '' }}</td>
              <td class="num" />
            </tr>
          </tfoot>
        </table>
      </div>

      <section v-if="coverage.length" class="costs-coverage" data-test="costs-coverage">
        <h3>{{ t('monitoring.costs.coverage_title') }}</h3>
        <ul>
          <li v-for="c in coverage" :key="c.source" data-test="costs-coverage-row" :data-source="c.source" :data-complete="c.complete ? '1' : '0'">
            <span class="costs-cov-source">{{ sourceLabel(c.source) }}</span>
            <span>{{ t('monitoring.costs.coverage_row', { n: c.ok, total: c.days }) }}</span>
            <span v-if="c.partial" class="costs-cov-gap">{{ t('monitoring.costs.coverage_partial', { n: c.partial }) }}</span>
            <span v-if="c.missing" class="costs-cov-gap">{{ t('monitoring.costs.coverage_missing', { n: c.missing }) }}</span>
            <span v-if="c.unrecorded" class="costs-cov-gap">{{ t('monitoring.costs.coverage_unrecorded', { n: c.unrecorded }) }}</span>
          </li>
        </ul>
      </section>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { COSTS_READ, costCoverageRows, costEmptySources, costMoney, costMonthOf, costMonthOptions, costPartKey, costPieSlices, costSecondCell, costSliceColor, costUnits } from '~/utils/tenant-costs.mjs'

/* the pie is this route's own chunk, never the shell's (ci_costs_route_gzip_kb) */
const MonitoringCostsPie = defineAsyncComponent(() => import('@/components/MonitoringCostsPie.vue'))

type CostsApi = { getTenantCosts: (month?: string, secondCurrency?: string) => Promise<unknown> }
type CostMonth = ReturnType<typeof costMonthOf>
type CostPart = CostMonth['parts'][number]

const { t, te, locale } = useI18n({ useScope: 'global' })
const months = costMonthOptions(new Date())
const month = ref(months[0])
const view = ref<CostMonth | null>(null)
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const forbiddenPerm = ref(COSTS_READ)
const session = useSessionStore()
/* the reader's pick; the hub converts by the session's, the mock is handed it */
const pick = computed(() => String(session.claims?.second_currency || ''))

const money = (micros: number, cur: string) => costMoney(micros, cur, locale.value)
const units = (p: CostPart) => costUnits(p.units, locale.value)
const partKey = (p: CostPart) => costPartKey(p)
const sourceLabel = (s: string) => (te('monitoring.costs.source.' + s) ? t('monitoring.costs.source.' + s) : s)
const secondHead = computed(() => t('monitoring.costs.col_second', { currency: view.value?.secondCurrency || 'EUR' }))
function second(p: { secondMicros: number | null, fxRate?: number | null, fxRateDay?: string, fxRateFirstDay?: string }) {
  const c = costSecondCell(p, view.value?.secondCurrency, locale.value)
  const title = c.key === 'none' ? t('monitoring.costs.second_none', c.params)
    : c.key === 'rate_span' ? t('monitoring.costs.second_rate_span', c.params)
      : c.key === 'rate' ? t('monitoring.costs.second_rate', c.params) : undefined
  return { text: c.text, none: c.none, title }
}
const partLabel = (p: CostPart) => `${sourceLabel(p.source)} · ${p.projectOrVendor || '-'} · ${p.kind}`

const empties = computed(() => (view.value ? costEmptySources(view.value) : []))
const coverage = computed(() => (view.value ? costCoverageRows(view.value) : []))
const slices = computed(() => (view.value ? costPieSlices(view.value.parts) : []).map((s, i) => ({
  key: s.key,
  d: s.d,
  pct: s.pct,
  color: costSliceColor(s, i),
  label: s.other || !s.part ? t('monitoring.costs.other', { n: s.n }) : partLabel(s.part),
  pctText: s.pct + ' %',
})))

let seq = 0
async function load(m: string) {
  const mine = ++seq
  state.value = 'loading'
  try {
    const body = await (useSpoolApi() as unknown as CostsApi).getTenantCosts(m === months[0] ? '' : m, pick.value)
    if (mine !== seq) return
    view.value = costMonthOf(body)
    state.value = 'ok'
  } catch (e) {
    if (mine !== seq) return
    view.value = null
    const err = e as { status?: number, permission?: string }
    if (err && err.status === 403) {
      forbiddenPerm.value = err.permission || COSTS_READ
      state.value = 'forbidden'
    } else state.value = 'error'
  }
}

onMounted(() => {
  watch(month, (m) => { void load(m) }, { immediate: true })
  watch(pick, () => { void load(month.value) })
})
</script>

<style scoped>
.monitoring-costs { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.costs-head { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; }
.costs-month { display: flex; align-items: center; gap: 8px; }
.costs-so-far { font-weight: 600; color: var(--color-warn); }
.costs-forbidden, .costs-error { color: var(--color-danger); }
.costs-empties { margin: 0; padding-left: 18px; color: var(--color-muted); }
.costs-table-wrap { overflow-x: auto; max-width: 100%; }
.costs-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.costs-table th, .costs-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
.costs-table .num { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
.costs-table tfoot th, .costs-table tfoot td { font-weight: 600; border-bottom: 0; }
.costs-part { overflow-wrap: anywhere; }
.costs-kind { display: block; }
.costs-hand { margin-inline-start: 6px; padding: 0 6px; border: 1px solid var(--color-border); border-radius: var(--radius-pill); font-size: 0.75rem; white-space: nowrap; }
.costs-coverage h3 { font-size: 0.9375rem; margin: 0 0 6px; }
.costs-coverage ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.costs-coverage li { display: flex; flex-wrap: wrap; gap: 4px 10px; }
.costs-cov-source { font-weight: 600; }
.costs-cov-gap { color: var(--color-warn); }
/* a phone: each part is a card, its figures labelled under the name (no sideways scroll) */
@media (max-width: 600px) {
  .costs-table thead { display: none; }
  .costs-table tr { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 2px 12px; padding: 6px 0; border-bottom: 1px solid var(--color-border); }
  .costs-table th, .costs-table td { border-bottom: 0; padding: 0 4px; }
  .costs-table tr > :first-child { grid-column: 1 / -1; }
  .costs-table .num { text-align: start; }
  .costs-table .num:empty { display: none; }
  .costs-table .num[data-label]::before { content: attr(data-label) ": "; color: var(--color-muted); }
}
</style>
