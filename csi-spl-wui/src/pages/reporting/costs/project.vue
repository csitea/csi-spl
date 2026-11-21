<!-- Spec 123 section 13, row P05 (SPL-6117; owner HUM-10, t1 e2c0e6b4, msgs
     3a190b70 "These the costs of this project" and 143a0a1c "the importance
     is to be able to see the monthly and yearly costs"): Reporting -> Costs
     -> The project's cost, cloud + owned hardware + AI tokens + human over
     GET /v1/tenant/costs/project (rows P01, P03). It opens on two figures,
     this month so far and this year to date, each split in its parts
     (13.12 item 2); then the table of the header's period (a month or the
     year to date; the hub reads no "last 12 months", so that pick draws the
     year to date and says so): each part's amount in the header's currency,
     its share of the priced total and its completeness in words (13.5), a
     "Total, priced" row; then a section per part linking to the page that
     holds its detail (13.2). A part the hub does not know is a dash, never
     0.00, and no sum holds it. Human money only with hours.rates (13.6):
     the hub's human_mask says what is hidden. Its own route and chunk, the
     first label of the Costs bar and its default (owner Q-9 A, t1 e2c0e6b4,
     msg 3a795cdb). -->
<template>
  <section class="cost-project" data-test="cost-project" data-section="project">
    <h3 class="cost-project-title" data-test="costs-label-title">{{ t('reporting.costs.project.title') }}</h3>
    <p v-if="state === 'loading'" class="muted" data-test="costs-loading">{{ t('monitoring.costs.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="cost-project-error" data-test="costs-forbidden">{{ t('monitoring.costs.forbidden', { perm: forbiddenPerm }) }}</p>
    <p v-else-if="state === 'error'" class="cost-project-error" data-test="costs-error">{{ t('monitoring.costs.error') }}</p>
    <template v-else-if="monthView && yearView && periodView">
      <div class="cost-project-figures" role="group" :aria-label="t('reporting.costs.project.figures_label')" data-test="project-figures">
        <div v-for="f in figures" :key="f.id" class="cost-project-figure" :data-test="'project-figure-' + f.id" :data-micros="micros(f.view.total)">
          <span class="muted">{{ f.label }}</span>
          <strong class="cost-project-figure-value" data-test="project-figure-value">{{ cell(f.view.total) }}</strong>
          <span v-if="f.view.total.partial" class="cost-project-partial" data-test="project-figure-partial">{{ t('reporting.costs.project.total_partial') }}</span>
          <ul class="cost-project-figure-parts">
            <li v-for="p in f.view.parts" :key="p.part" data-test="project-figure-part" :data-part="p.part" :data-micros="micros(p)">
              <span>{{ t('reporting.costs.project.part.' + p.part) }}</span>
              <span :title="amountTitle(p)">{{ cell(p) }}</span>
            </li>
          </ul>
        </div>
      </div>

      <div class="cost-project-notes">
        <span class="muted" data-test="costs-scope">{{ t(periodView.scope === 'estate' ? 'monitoring.costs.scope_estate' : 'monitoring.costs.scope_workspace') }}</span>
        <span v-if="periodView.status === 'so_far'" class="cost-project-so-far" data-test="costs-so-far">{{ t('monitoring.costs.so_far', { n: periodView.daysEnded, total: periodView.days }) }}</span>
      </div>
      <p v-if="l12m" class="muted" data-test="project-l12m-note">{{ t('reporting.costs.project.l12m_note') }}</p>

      <div class="cost-project-table-wrap">
        <table class="cost-project-table" data-test="project-table">
          <caption>{{ t('reporting.costs.project.table_label', { period: periodName }) }}</caption>
          <thead>
            <tr>
              <th scope="col">{{ t('reporting.costs.project.col_part') }}</th>
              <th scope="col" class="num">{{ t('reporting.costs.project.col_amount', { currency }) }}</th>
              <th scope="col" class="num">{{ t('reporting.costs.col_share') }}</th>
              <th scope="col">{{ t('reporting.costs.project.col_done') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="p in periodView.parts" :key="p.part" data-test="project-row" :data-part="p.part" :data-micros="micros(p)">
              <th scope="row"><a :href="'#project-part-' + p.part" data-test="project-row-link">{{ t('reporting.costs.project.part.' + p.part) }}</a></th>
              <td class="num" data-test="project-amount" :title="amountTitle(p)">{{ cell(p) }}</td>
              <td class="num" data-test="project-share">{{ p.share === null ? DASH : shareText(p.share) }}</td>
              <td data-test="project-done" :data-done="p.completeness">{{ doneText(p) }}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr data-test="project-total" :data-micros="micros(periodView.total)">
              <th scope="row">{{ t('reporting.costs.project.total') }}</th>
              <td class="num" data-test="project-amount">{{ cell(periodView.total) }}</td>
              <td class="num">{{ sumPositive ? shareText(100) : DASH }}</td>
              <td data-test="project-done">{{ t(periodView.total.partial ? 'reporting.costs.project.total_partial' : 'reporting.costs.project.total_complete') }}</td>
            </tr>
          </tfoot>
        </table>
      </div>
      <p v-if="periodView.humanMask !== 'none'" class="muted" data-test="project-mask-note" :data-mask="periodView.humanMask">{{ t('reporting.costs.project.mask_' + periodView.humanMask) }}</p>
      <ul v-if="periodView.leftOut.length" class="cost-project-left-out" data-test="project-left-out">
        <li v-for="(l, i) in periodView.leftOut" :key="i">{{ t('reporting.costs.project.left_out', { item: l.projectOrVendor || l.source, amount: l.unpriced ? DASH : costMoney(l.usd, 'USD', locale) }) }}</li>
      </ul>

      <section v-for="p in periodView.parts" :id="'project-part-' + p.part" :key="p.part" class="cost-project-part" data-test="project-section" :data-part="p.part">
        <h4>{{ t('reporting.costs.project.part.' + p.part) }}</h4>
        <p>{{ t('reporting.costs.project.section.' + p.part) }}</p>
        <NuxtLink :to="{ path: localePath(linkOf(p.part)), query: carried }" data-test="project-section-link">{{ t('reporting.costs.project.open.' + p.part) }}</NuxtLink>
      </section>
    </template>
  </section>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { COST_PROJECT_LINKS, costProjectAmount, costProjectDoneOf, costProjectOf } from '~/utils/cost-project.mjs'
import { COSTS_L12M, COSTS_YTD, costsCurrency, costsCurrencyOptions, costsMonthOptions, costsPeriod } from '~/utils/reporting-costs.mjs'
import { COSTS_READ, costMoney } from '~/utils/tenant-costs.mjs'

type View = ReturnType<typeof costProjectOf>
type Money = { usd: number | null, eur: number | null, second: number | null }
type Part = View['parts'][number]
type ProjectApi = { getTenantCostsProject: (period: { month?: string, year?: string }, secondCurrency?: string) => Promise<unknown> }

const DASH = '—'
const { t, locale } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const session = useSessionStore()

const pick = computed(() => String(session.claims?.second_currency || ''))
const current = costsMonthOptions(new Date())[0]
const thisYear = current.slice(0, 4)
const period = computed(() => costsPeriod(route.query.month, new Date()) || current)
const l12m = computed(() => period.value === COSTS_L12M)
const currency = computed(() => costsCurrency(route.query.currency, costsCurrencyOptions(pick.value)))
const carried = computed(() => {
  const q: Record<string, string> = {}
  for (const k of ['month', 'currency']) if (typeof route.query[k] === 'string') q[k] = route.query[k] as string
  return q
})

const monthView = ref<View | null>(null)
const yearView = ref<View | null>(null)
const pastView = ref<View | null>(null)
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const forbiddenPerm = ref(COSTS_READ)

/* the table's period: the year to date for ytd and l12m, else the month */
const spansYear = computed(() => period.value === COSTS_YTD || l12m.value)
const periodView = computed(() => (spansYear.value ? yearView.value : period.value === current ? monthView.value : pastView.value))
const periodName = computed(() => (spansYear.value ? t('reporting.costs.period_ytd', { year: thisYear }) : period.value === current ? t('monitoring.costs.month_so_far', { month: current }) : period.value))
const figures = computed(() => [
  { id: 'month', label: t('reporting.costs.project.month_so_far', { month: current }), view: monthView.value as View },
  { id: 'year', label: t('reporting.costs.project.year_to_date', { year: thisYear }), view: yearView.value as View },
])
const linkOf = (part: string) => (COST_PROJECT_LINKS as Record<string, string>)[part] || '/reporting/costs/total'
const sumPositive = computed(() => (amount(periodView.value?.total) ?? 0) > 0)

function amount(m: Money | undefined | null) {
  return m ? costProjectAmount(m, currency.value, periodView.value?.secondCurrency || '') : null
}
/** an amount's cell: the money, or a dash when the hub does not know it (never 0.00) */
function cell(m: Money) {
  const v = amount(m)
  return v === null ? DASH : costMoney(v, currency.value, locale.value)
}
const micros = (m: Money) => { const v = amount(m); return v === null ? '' : String(v) }
const amountTitle = (p: Part) => (amount(p) === null ? t('reporting.costs.project.unknown') : undefined)
const shareText = (v: number) => new Intl.NumberFormat(locale.value, { maximumFractionDigits: 1 }).format(v) + ' %'
function doneText(p: Part) {
  const d = costProjectDoneOf(p)
  const words = t('reporting.costs.project.done.' + d.key, d.params)
  return p.part === 'human' && periodView.value?.humanMask === 'money' ? words + ' · ' + t('reporting.costs.project.money_hidden') : words
}

let seq = 0
async function load() {
  const mine = ++seq
  state.value = 'loading'
  const api = useSpoolApi() as unknown as ProjectApi
  const past = !spansYear.value && period.value !== current ? period.value : ''
  try {
    const [m, y, p] = await Promise.all([
      api.getTenantCostsProject({}, pick.value),
      api.getTenantCostsProject({ year: thisYear }, pick.value),
      past ? api.getTenantCostsProject({ month: past }, pick.value) : Promise.resolve(null),
    ])
    if (mine !== seq) return
    monthView.value = costProjectOf(m)
    yearView.value = costProjectOf(y)
    pastView.value = p ? costProjectOf(p) : null
    state.value = 'ok'
  } catch (e) {
    if (mine !== seq) return
    const err = e as { status?: number, permission?: string }
    forbiddenPerm.value = err?.permission || COSTS_READ
    state.value = err?.status === 403 ? 'forbidden' : 'error'
  }
}
onMounted(() => {
  watch(() => [period.value, pick.value], () => { void load() }, { immediate: true })
})
</script>

<style scoped>
.cost-project { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.cost-project-title { margin: 0; font-size: 1rem; }
.cost-project-error { color: var(--color-danger); }
.cost-project-figures { display: grid; grid-template-columns: repeat(auto-fit, minmax(14rem, 1fr)); gap: 12px; }
.cost-project-figure { display: flex; flex-direction: column; gap: 4px; padding: 12px; border: 1px solid var(--color-border); border-radius: var(--radius); min-width: 0; }
.cost-project-figure-value { font-size: 1.5rem; }
.cost-project-figure-parts { list-style: none; margin: 4px 0 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.cost-project-figure-parts li { display: flex; justify-content: space-between; gap: 8px; }
.cost-project-partial { color: var(--color-warn); }
.cost-project-notes { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; }
.cost-project-so-far { font-weight: 600; color: var(--color-warn); }
.cost-project-table-wrap { min-width: 0; }
.cost-project-table { width: 100%; border-collapse: collapse; table-layout: fixed; }
.cost-project-table caption { text-align: start; font-weight: 600; padding-bottom: 4px; }
.cost-project-table th, .cost-project-table td { padding: 6px 4px; border-bottom: 1px solid var(--color-border); text-align: start; overflow-wrap: anywhere; vertical-align: top; }
.cost-project-table .num { text-align: end; }
.cost-project-left-out { margin: 0; padding-inline-start: 1.25rem; }
.cost-project-part h4 { margin: 0 0 4px; font-size: 0.875rem; }
.cost-project-part p { margin: 0 0 4px; }
</style>
