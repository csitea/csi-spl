<!-- SPL-4187 (spec 123 5.5; owner HUM-10, t1 e2c0e6b4, msgs 81217a3f "all of
     the expenses from the cloud ... their own section", 8c7f4962 "the first
     level by gcp project of the cloud costs, than there should be drill down
     by service etc."): Reporting -> Costs -> Cloud. Level 1 one row per GCP
     project of the month (its box= label apart), level 2 a project's
     services (the line kind), both from GET /v1/tenant/costs; level 3 a
     service per day from GET /v1/tenant/costs/cloud. The level rides in the
     query (?project=, &kind=) beside the header's month and currency, so
     the back button walks up. Money in the header's currency; a day with no
     rate is a dash saying so, never a guess. The estate's: drawn for an
     operator admin only (hiding only, the hub's 403 is the control). -->
<template>
  <section class="costs-cloud" data-test="costs-cloud" :data-level="level">
    <h3>{{ t('reporting.costs.cloud.title') }}</h3>
    <p v-if="!operator.visible" class="muted" data-test="reporting-operators-only">{{ t('reporting.future.operators_only') }}</p>
    <template v-else>
      <nav class="cloud-crumbs" :aria-label="t('reporting.costs.cloud.crumbs_label')" data-test="cloud-crumbs">
        <NuxtLink v-if="project" :to="levelTo('', '')" data-test="cloud-crumb-all">{{ t('reporting.costs.cloud.all_projects') }}</NuxtLink>
        <span v-else aria-current="page">{{ t('reporting.costs.cloud.all_projects') }}</span>
        <template v-if="project">
          <span aria-hidden="true">›</span>
          <NuxtLink v-if="kind" :to="levelTo(project, '')" data-test="cloud-crumb-project">{{ project }}</NuxtLink>
          <span v-else aria-current="page" data-test="cloud-crumb-project">{{ project }}</span>
        </template>
        <template v-if="kind">
          <span aria-hidden="true">›</span>
          <span aria-current="page" data-test="cloud-crumb-kind">{{ kind }}</span>
        </template>
      </nav>

      <p v-if="state === 'loading'" class="muted" data-test="cloud-loading">{{ t('monitoring.costs.loading') }}</p>
      <p v-else-if="state === 'forbidden'" class="cloud-error" data-test="cloud-forbidden">{{ t('reporting.future.operators_only') }}</p>
      <p v-else-if="state === 'error'" class="cloud-error" data-test="cloud-error">{{ t('monitoring.costs.error') }}</p>
      <template v-else>
        <p v-if="coverage" class="muted" data-test="cloud-coverage">{{ t('monitoring.costs.coverage_row', { n: coverage.ok, total: coverage.days }) }}</p>
        <div class="cloud-table-wrap">
          <table class="cloud-table" data-test="cloud-table">
            <thead>
              <tr>
                <th scope="col">{{ t(colKey) }}</th>
                <th scope="col" class="num" data-test="cloud-currency">{{ currency }}</th>
                <th scope="col" class="num">{{ t('monitoring.costs.col_pct') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="r in rows" :key="r.key" data-test="cloud-row" :data-key="r.key">
                <td>
                  <NuxtLink v-if="r.to" :to="r.to" class="cloud-name" data-test="cloud-drill">{{ r.label }}</NuxtLink>
                  <span v-else class="cloud-name">{{ r.label }}</span>
                  <span v-if="r.box" class="cloud-box" data-test="cloud-box">{{ t('reporting.costs.cloud.box', { box: r.box }) }}</span>
                  <span v-if="r.sub" class="cloud-sub muted">{{ r.sub }}</span>
                </td>
                <td class="num" data-test="cloud-amount" :title="r.amount.title">{{ r.amount.text }}</td>
                <td class="num">{{ r.pct }}</td>
              </tr>
              <tr v-if="!rows.length">
                <td colspan="3" class="muted" data-test="cloud-empty">{{ t('reporting.costs.cloud.empty') }}</td>
              </tr>
            </tbody>
            <tfoot v-if="rows.length">
              <tr data-test="cloud-total">
                <th scope="row">{{ t('monitoring.costs.total') }}</th>
                <td class="num" data-test="cloud-total-amount" :title="total.title">{{ total.text }}</td>
                <td class="num">100 %</td>
              </tr>
            </tfoot>
          </table>
        </div>
      </template>
    </template>
  </section>
</template>

<script setup lang="ts">
import type { LocationQueryRaw } from 'vue-router'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { useOperatorPane } from '~/stores/operator-pane'
import { costsCurrency, costsCurrencyOptions, costsMonth, costsMonthOptions } from '~/utils/reporting-costs.mjs'
import { costMoney, costMonthOf } from '~/utils/tenant-costs.mjs'
import { CLOUD_SOURCE, cloudDaysOf, cloudProjects, cloudServiceDays, cloudServices, cloudTotal, sectionAmount } from '~/utils/costs-sections.mjs'

type CloudApi = {
  getTenantCosts: (month?: string, secondCurrency?: string) => Promise<unknown>
  getCloudCostDays: (month?: string, project?: string, secondCurrency?: string) => Promise<unknown>
}
type Money = { usdMicros: number, eurMicros: number, secondMicros: number | null }
type Row = Money & { key: string, label: string, box?: string, sub?: string, to?: { query: LocationQueryRaw } }

const { t, locale } = useI18n({ useScope: 'global' })
const route = useRoute()
const session = useSessionStore()
const operator = useOperatorPane()
const pick = computed(() => String(session.claims?.second_currency || ''))
const current = costsMonthOptions(new Date())[0]
const month = computed(() => { const m = costsMonth(route.query.month); return m === current ? '' : m })
const currency = computed(() => costsCurrency(route.query.currency, costsCurrencyOptions(pick.value)))
const qs = (k: string) => (typeof route.query[k] === 'string' ? route.query[k] as string : '')
const project = computed(() => qs('project'))
const kind = computed(() => (project.value ? qs('kind') : ''))
const level = computed(() => (kind.value ? 'day' : project.value ? 'service' : 'project'))
const colKey = computed(() => 'reporting.costs.cloud.col_' + level.value)

const view = ref<ReturnType<typeof costMonthOf> | null>(null)
const days = ref<ReturnType<typeof cloudDaysOf> | null>(null)
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')

/** a level's link: the query with project and kind set (or dropped), the header's picks kept */
function levelTo(p: string, k: string) {
  const q: LocationQueryRaw = { ...route.query }
  delete q.project
  delete q.kind
  if (p) q.project = p
  if (k) q.kind = k
  return { query: q }
}
function cell(m: Money) {
  const v = sectionAmount(m, currency.value)
  if (v === null || v === undefined) return { text: '—', title: t('monitoring.costs.second_none', { currency: currency.value }) }
  return { text: costMoney(v, currency.value, locale.value), title: undefined }
}

const base = computed<Row[]>(() => {
  const parts = view.value?.parts || []
  if (level.value === 'project') {
    return cloudProjects(parts).map((r) => ({ ...r, label: r.project, sub: t('reporting.costs.cloud.services', { n: r.services }), to: levelTo(r.pov, '') }))
  }
  if (level.value === 'service') {
    return cloudServices(parts, project.value).map((r) => ({ ...r, label: r.kind, sub: t('reporting.costs.cloud.days', { n: r.days }), to: levelTo(project.value, r.kind) }))
  }
  return cloudServiceDays(days.value, kind.value).map((d: Money & { day: string }) => ({ ...d, key: d.day, label: d.day }))
})
const sum = computed(() => cloudTotal(base.value))
const rows = computed(() => base.value.map((r) => ({
  ...r,
  amount: cell(r),
  pct: sum.value.usdMicros > 0 ? Math.round((r.usdMicros * 1000) / sum.value.usdMicros) / 10 + ' %' : '',
})))
const total = computed(() => cell(sum.value))
const coverage = computed(() => view.value?.coverage.find((c: { source: string }) => c.source === CLOUD_SOURCE) || null)

let seq = 0
async function load() {
  const mine = ++seq
  state.value = 'loading'
  const api = useSpoolApi() as unknown as CloudApi
  try {
    const [m, d] = await Promise.all([
      api.getTenantCosts(month.value, pick.value),
      kind.value ? api.getCloudCostDays(month.value, project.value, pick.value) : Promise.resolve(null),
    ])
    if (mine !== seq) return
    view.value = costMonthOf(m)
    days.value = d === null ? null : cloudDaysOf(d)
    state.value = 'ok'
  } catch (e) {
    if (mine !== seq) return
    state.value = (e as { status?: number })?.status === 403 ? 'forbidden' : 'error'
  }
}

onMounted(() => {
  watch(() => [operator.visible, month.value, pick.value, project.value, kind.value], () => { if (operator.visible) void load() }, { immediate: true })
})
</script>

<style scoped>
.costs-cloud { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.costs-cloud h3 { margin: 0; font-size: 1rem; }
.cloud-crumbs { display: flex; flex-wrap: wrap; gap: 4px 8px; align-items: center; overflow-wrap: anywhere; }
.cloud-error { color: var(--color-danger); }
.cloud-table-wrap { max-width: 100%; overflow-x: auto; }
.cloud-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.cloud-table th, .cloud-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
.cloud-table .num { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
.cloud-table tfoot th, .cloud-table tfoot td { font-weight: 600; border-bottom: 0; }
.cloud-name { overflow-wrap: anywhere; }
.cloud-box { margin-inline-start: 6px; padding: 0 6px; border: 1px solid var(--color-border); border-radius: var(--radius-pill); font-size: 0.75rem; white-space: nowrap; }
.cloud-sub { display: block; font-size: 0.75rem; }
</style>
