<!-- Spec 143 costs-redesign.md 3.1 rules 2-3, slice S1 (SPL-3798, owner
     HUM-10, t1 1be0e370, msg 3f1c7128, answer 2 A): the Costs header, one
     month and one currency for all four pages. Both ride in the query
     (`?month=YYYY-MM`, `?currency=XXX`; the current month and USD are the
     defaults and leave it), so switching pages and the back button keep
     them. Months: the current UTC month "so far" back to the first month
     holding a cost line (utils/reporting-costs.mjs). Currency: USD or the
     reader's second currency (Settings -> Appearance, EUR unless picked). -->
<template>
  <div class="costs-header" data-test="costs-header">
    <label class="costs-header-month">
      <span>{{ t('monitoring.costs.month') }}</span>
      <select :value="month" data-test="costs-header-month" @change="pickMonth">
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
import { costsCurrency, costsCurrencyOptions, costsMonth, costsMonthOptions, costsQueryWith } from '~/utils/reporting-costs.mjs'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()
const session = useSessionStore()

const months = computed(() => costsMonthOptions(new Date(), undefined, costsMonth(route.query.month)))
const month = computed(() => costsMonth(route.query.month) || months.value[0])
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
