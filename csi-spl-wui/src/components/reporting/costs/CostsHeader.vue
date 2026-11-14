<!-- Spec 143 costs-redesign.md 3.1 rules 2-3, slice S1 (SPL-3798, owner
     HUM-10, t1 1be0e370, msg 3f1c7128, answer 2 A): the Costs header, one
     month and one currency for all four pages. Both ride in the query
     (`?month=YYYY-MM`, `?currency=XXX`; the current month and USD are the
     defaults and leave it), so switching pages and the back button keep
     them. Months: the current UTC month "so far" back to the first month
     holding a cost line (utils/reporting-costs.mjs). Currency: USD or the
     reader's second currency (Settings -> Appearance, EUR unless picked).
     SPL-5312 (owner t1 41a74806: "a dropdown for the costs for each month
     for the last 12 months and from the start of the year"): the picker is
     the period, the year to date first (`?month=ytd`), then the current
     month "so far" and the 11 before it; an older month from a link is
     kept. SPL-5433 step b: "the last 12 months" (`?month=l12m`) second,
     the 12 months of the picker side by side. -->
<template>
  <div class="costs-header" data-test="costs-header">
    <label class="costs-header-month">
      <span>{{ t('reporting.costs.period') }}</span>
      <select :value="month" data-test="costs-header-month" @change="pickMonth">
        <option :value="COSTS_YTD" data-test="costs-period-ytd">{{ t('reporting.costs.period_ytd', { year: months[0].slice(0, 4) }) }}</option>
        <option :value="COSTS_L12M" data-test="costs-period-l12m">{{ t('reporting.costs.period_l12m') }}</option>
        <option v-for="(m, i) in months" :key="m" :value="m">{{ i === 0 ? t('monitoring.costs.month_so_far', { month: m }) : m }}</option>
      </select>
    </label>
    <div class="costs-header-currency" role="radiogroup" :aria-label="t('reporting.costs.currency')" data-test="costs-header-currency">
      <span class="muted">{{ t('reporting.costs.currency') }}</span>
      <button
        v-for="c in currencies"
        :key="c"
        type="button"
        role="radio"
        class="costs-header-cur"
        :class="{ 'costs-header-cur--on': currency === c }"
        :aria-checked="currency === c ? 'true' : 'false'"
        :data-test="'costs-header-cur-' + c"
        @click="pickCurrency(c)"
      >{{ c }}</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import type { LocationQueryRaw } from 'vue-router'
import { useSessionStore } from '~/stores/session'
import { COSTS_L12M, COSTS_YTD, costsCurrency, costsCurrencyOptions, costsMonth, costsMonthOptions, costsPeriod, costsQueryWith } from '~/utils/reporting-costs.mjs'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()
const session = useSessionStore()

const months = computed(() => costsMonthOptions(new Date(), costsMonth(route.query.month)))
const month = computed(() => costsPeriod(route.query.month, new Date()) || months.value[0])
const currencies = computed(() => costsCurrencyOptions(String(session.claims?.second_currency || '')))
const currency = computed(() => costsCurrency(route.query.currency, currencies.value))

function pickMonth(e: Event) {
  const m = (e.target as HTMLSelectElement).value
  void router.push({ query: costsQueryWith(route.query, { month: m, current: months.value[0] }) as LocationQueryRaw })
}
function pickCurrency(c: string) {
  void router.push({ query: costsQueryWith(route.query, { currency: c }) as LocationQueryRaw })
}
</script>
