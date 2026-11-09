<!-- SPL-4187 (spec 123 5.5 and 13.5; owner HUM-10, t1 e2c0e6b4, msg 81217a3f:
     "three main types of costs: cloud costs, AI token costs, and human
     costs"): Reporting -> Costs -> Human, a section of its own. Human costs
     are approved time at each person's own price (spec 107 section 21), not
     built yet: the page says "not tracked yet" and names the spec 107 rows
     that build it, never a number until they land.
     SPL-4840 (owner csitea f7bba506 poll d82c98e2, answer A "In Human; left
     out of Spend"): a month with hand-entered hr costs (the month read's
     human list, the estate's) lists them here, one row each in the header's
     currency, with a total; Spend leaves them out. One with no rate to USD is
     a dash saying so, and the total says how many it leaves out. Any other
     month, or any reader but an operator admin, keeps the "not tracked yet"
     line. -->
<template>
  <section class="costs-human" data-test="costs-human">
    <h3>{{ t('reporting.costs.human.title') }}</h3>
    <p v-if="state === 'loading'" class="muted" data-test="human-loading">{{ t('monitoring.costs.loading') }}</p>
    <p v-else-if="state === 'error'" class="human-error" data-test="human-error">{{ t('monitoring.costs.error') }}</p>
    <div v-else-if="rows.length" class="human-table-wrap">
      <table class="human-table" data-test="human-table">
        <thead>
          <tr>
            <th scope="col">{{ t('monitoring.costs.col_part') }}</th>
            <th scope="col" class="num" data-test="human-currency">{{ currency }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in rows" :key="r.key" data-test="human-row" :data-key="r.key" :data-unpriced="r.unpriced ? '1' : undefined">
            <td>
              <span class="human-name">{{ r.label }}</span>
              <span class="human-sub muted">{{ t('reporting.costs.cloud.entry', { amount: costMoney(r.entryMicros, r.entryCurrency, locale) }) }}</span>
            </td>
            <td class="num" data-test="human-amount" :title="r.amount.title">{{ r.amount.text }}</td>
          </tr>
        </tbody>
        <tfoot>
          <tr data-test="human-total">
            <th scope="row">{{ t('monitoring.costs.total') }}</th>
            <td class="num" data-test="human-total-amount" :data-left="(currency === 'USD' ? sum.unpricedRows : sum.secondLeftRows) || 0" :title="total.title">{{ total.text }}</td>
          </tr>
        </tfoot>
      </table>
    </div>
    <p v-else class="muted" data-test="costs-human-not-tracked">{{ t('reporting.costs.human.not_tracked', { rows: HUMAN_ROWS }) }}</p>
  </section>
</template>

<script setup lang="ts">
import { useOperatorReader } from '~/composables/useOperatorReader'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { costsCurrency, costsCurrencyOptions, costsMonth, costsMonthOptions } from '~/utils/reporting-costs.mjs'
import { costMoney, costMonthOf } from '~/utils/tenant-costs.mjs'
import { HUMAN_ROWS, cloudTotal, humanEntries, sectionAmount } from '~/utils/costs-sections.mjs'

type HumanApi = { getTenantCosts: (month?: string, secondCurrency?: string) => Promise<unknown> }
type Money = { usdMicros: number, eurMicros: number, secondMicros: number | null, unpriced?: boolean, entryCurrency?: string, unpricedRows?: number, secondLeftRows?: number }

const { t, locale } = useI18n({ useScope: 'global' })
const route = useRoute()
const session = useSessionStore()
const reader = useOperatorReader()
const pick = computed(() => String(session.claims?.second_currency || ''))
const current = costsMonthOptions(new Date())[0]
const month = computed(() => { const m = costsMonth(route.query.month); return m === current ? '' : m })
const currency = computed(() => costsCurrency(route.query.currency, costsCurrencyOptions(pick.value)))

/* 'idle': not an operator admin, so no read and the "not tracked yet" line */
const state = ref<'idle' | 'loading' | 'ok' | 'error'>('idle')
const human = ref<ReturnType<typeof costMonthOf>['human']>([])

function cell(m: Money) {
  const v = sectionAmount(m, currency.value)
  if (v === null || v === undefined) {
    const title = m.unpriced ? t('monitoring.costs.unpriced', { currency: m.entryCurrency }) : t('monitoring.costs.second_none', { currency: currency.value })
    return { text: '—', title }
  }
  const n = currency.value === 'USD' ? m.unpricedRows : m.secondLeftRows
  return { text: costMoney(v, currency.value, locale.value), title: n ? t('monitoring.costs.total_unpriced', { n }) : undefined }
}
const base = computed(() => humanEntries(human.value))
const sum = computed(() => cloudTotal(base.value))
const rows = computed(() => base.value.map((r) => ({ ...r, amount: cell(r) })))
const total = computed(() => cell(sum.value))

let seq = 0
async function load() {
  const mine = ++seq
  state.value = 'loading'
  try {
    const body = await (useSpoolApi() as unknown as HumanApi).getTenantCosts(month.value, pick.value)
    if (mine !== seq) return
    human.value = costMonthOf(body).human
    state.value = 'ok'
  } catch {
    if (mine !== seq) return
    human.value = []
    state.value = 'error'
  }
}

onMounted(() => {
  watch(() => [reader.value, month.value, pick.value], () => { if (reader.value) void load() }, { immediate: true })
})
</script>

<style scoped>
.costs-human { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.costs-human h3 { margin: 0; font-size: 1rem; }
.human-error { color: var(--color-danger); }
.human-table-wrap { max-width: 100%; overflow-x: auto; }
.human-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.human-table th, .human-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
.human-table .num { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
.human-table tfoot th, .human-table tfoot td { font-weight: 600; border-bottom: 0; }
.human-name { overflow-wrap: anywhere; }
.human-sub { display: block; font-size: 0.75rem; }
</style>
