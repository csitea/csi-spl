<!-- SPL-5312 (spec 143 costs-redesign.md 3.9; owner HUM-10, t1 41a74806,
     2026-11-11): one label of Reporting -> Costs (Total, Persons, Cloud or
     Tokens). Straight after its name: the pie of its items, each item's
     value and share written in the legend (not only on hover; a phone has
     none); then its table per month of the header's period (one of the
     last 12 months, or the year to date), sortable by any column name.
     The money is the reader's workspace's (the hub's scope: the operator
     admin reads the estate), in the header's currency, made by
     utils/costs-labels.mjs costsLabelRows, the one function a hand
     allocation of a shared cost (spec 143 costs-allocation.md) feeds.
     A workspace whose label has no split of its own in the hub's answer
     (Persons, Cloud: the estate's today) says so in place of a bare empty.
     Cloud keeps its drill (owner t1 e2c0e6b4, msg 8c7f4962): a project's
     services (?project=), and for a single month a service per day (&kind=). -->
<template>
  <section class="costs-label" data-test="costs-page" :data-section="section" :data-level="level">
    <h3 class="costs-label-title" data-test="costs-label-title">{{ title }}</h3>
    <p v-if="state === 'loading'" class="muted" data-test="costs-loading">{{ t('monitoring.costs.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="costs-label-error" data-test="costs-forbidden">{{ t('monitoring.costs.forbidden', { perm: forbiddenPerm }) }}</p>
    <p v-else-if="state === 'error'" class="costs-label-error" data-test="costs-error">{{ t('monitoring.costs.error') }}</p>
    <template v-else>
      <MonitoringCostsPie v-if="slices.length" :label="t('reporting.costs.pie_label')" :slices="slices" />
      <p v-else class="muted" data-test="costs-no-pie">{{ t('reporting.costs.no_pie') }}</p>

      <nav v-if="section === 'cloud' && project" class="costs-label-crumbs" :aria-label="t('reporting.costs.cloud.crumbs_label')" data-test="cloud-crumbs">
        <NuxtLink :to="levelTo('', '')" data-test="cloud-crumb-all">{{ t('reporting.costs.cloud.all_projects') }}</NuxtLink>
        <span aria-hidden="true">›</span>
        <NuxtLink v-if="kind" :to="levelTo(project, '')" data-test="cloud-crumb-project">{{ project }}</NuxtLink>
        <span v-else aria-current="page" data-test="cloud-crumb-project">{{ project }}</span>
        <template v-if="kind">
          <span aria-hidden="true">›</span>
          <span aria-current="page" data-test="cloud-crumb-kind">{{ kind }}</span>
        </template>
      </nav>

      <div class="costs-label-notes">
        <span v-if="soFar" class="costs-so-far" data-test="costs-so-far">{{ t('monitoring.costs.so_far', { n: soFar.daysEnded, total: soFar.days }) }}</span>
        <span class="muted" data-test="costs-scope">{{ t(scope === 'estate' ? 'monitoring.costs.scope_estate' : 'monitoring.costs.scope_workspace') }}</span>
      </div>
      <p v-if="noSplit" class="muted" data-test="costs-no-split">{{ t('reporting.costs.no_split') }}</p>
      <p v-if="shareNote" class="muted" data-test="costs-ai-share-note" :data-key="shareNote.key">{{ t('monitoring.costs.' + shareNote.key, shareNote.params) }}</p>

      <CostsMonthTable
        :rows="shown"
        :months="months"
        :totals="totals"
        :caption="t('reporting.costs.table_label')"
        :name-head="t(nameHeadKey)"
        :money="cellMoney"
        :none-title="t('monitoring.costs.second_none', { currency })"
        :empty="t('reporting.costs.empty')"
      />

      <CostsLabelExtras :section="section" :views="views" :single="months.length === 1" />
    </template>
  </section>
</template>

<script setup lang="ts">
import type { LocationQueryRaw } from 'vue-router'
import CostsMonthTable from '~/components/reporting/costs/CostsMonthTable.vue'
import CostsLabelExtras from '~/components/reporting/costs/CostsLabelExtras.vue'
import { useCostsPeriod } from '~/composables/useCostsPeriod'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { costsColumnTotals, costsDayRows, costsLabelRows, costsLabelSlices } from '~/utils/costs-labels.mjs'
import { cloudDaysOf } from '~/utils/costs-sections.mjs'
import { costAIShareNote, costMoney, costUnits } from '~/utils/tenant-costs.mjs'

/* the pie is the label pages' own chunk, never the shell's */
const MonitoringCostsPie = defineAsyncComponent(() => import('@/components/MonitoringCostsPie.vue'))

type DaysApi = { getCloudCostDays: (month?: string, project?: string, secondCurrency?: string) => Promise<unknown> }
type Cell = { v: number | null, left: number, empty: boolean }
type Row = ReturnType<typeof costsLabelRows>[number]

const props = defineProps<{ section: 'total' | 'persons' | 'cloud' | 'tokens' }>()
const { t, te, locale } = useI18n({ useScope: 'global' })
const route = useRoute()
const { months, currency, current, pick, views, state, forbiddenPerm } = useCostsPeriod()

const title = computed(() => t('reporting.costs.label.' + props.section))
const qs = (k: string) => (typeof route.query[k] === 'string' ? route.query[k] as string : '')
const project = computed(() => (props.section === 'cloud' ? qs('project') : ''))
const kind = computed(() => (project.value && months.value.length === 1 ? qs('kind') : ''))
const level = computed(() => (kind.value ? 'day' : project.value ? 'service' : 'item'))
const nameHeadKey = computed(() => ({ day: 'reporting.costs.cloud.col_day', service: 'reporting.costs.cloud.col_service', item: 'reporting.costs.col_item' })[level.value])
const scope = computed(() => views.value[0]?.scope || 'workspace')
const last = computed(() => views.value[views.value.length - 1] || null)
const soFar = computed(() => (last.value && last.value.status === 'so_far' ? last.value : null))
const shareNote = computed(() => (last.value && (props.section === 'tokens' || props.section === 'total') ? costAIShareNote(last.value) : null))

/** a level's link: the query with project and kind set (or dropped), the header's picks kept */
function levelTo(p: string, k: string) {
  const q: LocationQueryRaw = { ...route.query }
  delete q.project
  delete q.kind
  if (p) q.project = p
  if (k) q.kind = k
  return { query: q }
}

/* fleet_tokens.<box> reads as "Fleet tokens · <box>" */
function sourceLabel(s: string) {
  const [head, box] = [s.split('.')[0], s.split('.').slice(1).join('.')]
  const name = te('monitoring.costs.source.' + head) ? t('monitoring.costs.source.' + head) : head
  return box ? `${name} · ${box}` : name
}
function display(r: Row) {
  if (props.section === 'total') return t('reporting.costs.label.' + r.key)
  if (props.section === 'tokens') return `${sourceLabel(String(r.source))} · ${r.name || '-'}`
  if (props.section === 'persons' && r.group && te('expenses.hr.group.' + r.group)) return t('expenses.hr.group.' + r.group)
  return r.name
}
function sub(r: Row) {
  if (r.entryCurrency && r.entryMicros) return t('reporting.costs.cloud.entry', { amount: costMoney(r.entryMicros, r.entryCurrency, locale.value) })
  const units = props.section === 'tokens' ? costUnits(r.units, locale.value) : ''
  if (!units && !r.listMicros) return ''
  return t('reporting.costs.tokens_sub', { units: units || '0', list: costMoney(r.listMicros, 'USD', locale.value) })
}
function drill(r: Row) {
  if (props.section !== 'cloud' || !r.drill) return undefined
  if (r.drill === 'project') return levelTo(r.key, '')
  return months.value.length === 1 ? levelTo(project.value, r.key) : undefined
}

const days = ref<ReturnType<typeof cloudDaysOf> | null>(null)
const rows = computed(() => (kind.value
  ? costsDayRows(days.value, kind.value, currency.value)
  : costsLabelRows(props.section, views.value, { currency: currency.value, project: project.value })) as Row[])
const shown = computed(() => rows.value.map((r) => ({
  ...r,
  display: kind.value ? r.name : display(r),
  sub: kind.value ? '' : sub(r),
  badge: r.box ? t('reporting.costs.cloud.box', { box: r.box }) : r.hand ? t('monitoring.costs.hand') : '',
  to: drill(r),
})))
const totals = computed(() => costsColumnTotals(rows.value, months.value))
const cellMoney = (c: Cell) => costMoney(c.v ?? 0, currency.value, locale.value)
const slices = computed(() => costsLabelSlices(rows.value).map((s) => ({
  key: s.key,
  d: s.d,
  pct: s.pct,
  color: s.color,
  label: shown.value.find((r) => r.key === s.key)?.display || s.key,
  pctText: s.pct + ' %',
  valueText: costMoney(s.v, currency.value, locale.value),
})))
/* Persons and Cloud are the estate's in the hub's answer: a workspace has no split of its own yet */
const noSplit = computed(() => scope.value === 'workspace' && (props.section === 'persons' || props.section === 'cloud') && !rows.value.length)

let seq = 0
async function loadDays() {
  const mine = ++seq
  if (!kind.value) return
  try {
    const m = months.value[0]
    const d = await (useSpoolApi() as unknown as DaysApi).getCloudCostDays(m === current ? '' : m, project.value, pick.value)
    if (mine === seq) days.value = cloudDaysOf(d)
  } catch {
    if (mine === seq) days.value = null
  }
}
onMounted(() => {
  watch(() => [kind.value, project.value, months.value.join(','), pick.value], () => { void loadDays() }, { immediate: true })
})
</script>

<style scoped>
.costs-label { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.costs-label-title { margin: 0; font-size: 1rem; }
.costs-label-error { color: var(--color-danger); }
.costs-label-crumbs { display: flex; flex-wrap: wrap; gap: 4px 8px; align-items: center; overflow-wrap: anywhere; }
.costs-label-notes { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; }
.costs-so-far { font-weight: 600; color: var(--color-warn); }
</style>
