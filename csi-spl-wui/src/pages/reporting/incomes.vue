<!-- SPL-4697 (spec 143 incomes.md; owner HUM-10, csitea topic 450418ab, msg
     e793f8d0): the Reporting Incomes tab. One row per month of the chosen
     year, the year's totals per currency below. Analytics only (incomes.md
     0): the accounting system stays the record, this page never writes. The
     hub (GET /v1/reporting/incomes) is the control: it answers 403 to anyone
     but the workspace's owner, and this page then shows that line and no
     table. -->
<template>
  <div class="reporting-incomes" data-test="reporting-incomes">
    <p v-if="state === 'loading'" class="muted" role="status" data-test="reporting-incomes-loading">{{ t('reporting.incomes.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="muted" role="alert" data-test="reporting-incomes-forbidden">{{ t('reporting.incomes.forbidden') }}</p>
    <p v-else-if="state === 'error'" class="inc-error" role="alert" data-test="reporting-incomes-error">{{ t('reporting.incomes.error') }}</p>
    <template v-else-if="report">
      <label class="inc-year">
        <span>{{ t('reporting.incomes.year') }}</span>
        <select v-model.number="year" data-test="reporting-incomes-year" @change="load(year)">
          <option v-for="y in years" :key="y" :value="y">{{ y }}</option>
        </select>
      </label>
      <p v-if="!report.invoices.length" class="muted" data-test="reporting-incomes-empty">{{ t('reporting.incomes.empty', { year: report.year }) }}</p>
      <div v-else class="inc-scroll">
        <table class="inc-table" :aria-label="t('reporting.incomes.table_label', { year: report.year })" data-test="reporting-incomes-table">
          <thead>
            <tr>
              <th scope="col">{{ t('reporting.incomes.col.month') }}</th>
              <th scope="col" class="inc-opt">{{ t('reporting.incomes.col.invoice') }}</th>
              <th scope="col" class="inc-opt">{{ t('reporting.incomes.col.issued') }}</th>
              <th scope="col" class="inc-opt">{{ t('reporting.incomes.col.due') }}</th>
              <th scope="col" class="num">{{ t('reporting.incomes.col.hours') }}</th>
              <th scope="col" class="num">{{ t('reporting.incomes.col.net') }}</th>
              <th scope="col" class="num inc-opt">{{ t('reporting.incomes.col.vat') }}</th>
              <th scope="col" class="num">{{ t('reporting.incomes.col.total') }}</th>
            </tr>
          </thead>
          <tbody>
            <template v-for="row in rows" :key="row.month">
              <tr v-if="!row.invoices.length" class="inc-gap" :data-test="'reporting-incomes-month-' + row.month">
                <th scope="row">{{ monthName(row.month) }}</th>
                <td colspan="7" :aria-label="t('reporting.incomes.no_invoice')">–</td>
              </tr>
              <tr v-for="inv in row.invoices" v-else :key="inv.invoice_no" :data-test="'reporting-incomes-month-' + row.month">
                <th scope="row">{{ monthName(row.month) }}</th>
                <td class="inc-opt">{{ inv.invoice_no }}</td>
                <td class="inc-opt">{{ inv.issue_date }}</td>
                <td class="inc-opt">{{ inv.due_date }}</td>
                <td class="num">{{ hoursText(inv.hours) }}</td>
                <td class="num">{{ money(inv.net, inv.currency) }}</td>
                <td class="num inc-opt">{{ money(inv.vat, inv.currency) }}</td>
                <td class="num">{{ money(inv.total, inv.currency) }}</td>
              </tr>
            </template>
          </tbody>
          <tfoot>
            <tr v-for="tot in totals" :key="tot.currency" class="inc-total" :data-test="'reporting-incomes-total-' + tot.currency">
              <th scope="row">{{ t('reporting.incomes.year_total', { year: report.year }) }}</th>
              <td class="inc-opt" />
              <td class="inc-opt" />
              <td class="inc-opt" />
              <td class="num">{{ hoursText(tot.hours) }}</td>
              <td class="num">{{ money(tot.net, tot.currency) }}</td>
              <td class="num inc-opt">{{ money(tot.vat, tot.currency) }}</td>
              <td class="num">{{ money(tot.total, tot.currency) }}</td>
            </tr>
          </tfoot>
        </table>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { gateMe, ownerReadable } from '~/utils/read-gates.mjs'
import { formatIncomeAmount, incomeMonthRows, incomeYearTotals, incomesReportRead } from '~/utils/reporting-incomes.mjs'

const { t, locale } = useI18n({ useScope: 'global' })
const api = useSpoolApi() as unknown as Parameters<typeof incomesReportRead>[0]

type Report = Awaited<ReturnType<typeof incomesReportRead>>
const state = ref<'loading' | 'ready' | 'forbidden' | 'error'>('loading')
const report = ref<Report | undefined>(undefined)
const year = ref<number>(0)
const rows = computed(() => incomeMonthRows(report.value))
const totals = computed(() => incomeYearTotals(report.value))
/* the hub's years with rows, plus the one shown (an empty year still picks) */
const years = computed(() => [...new Set([...(report.value?.years || []), report.value?.year || year.value])].sort((a, b) => b - a))

/* dates are ISO everywhere (tests/unit/date-iso.test.mjs): the month is its YYYY-MM */
const monthName = (m: string) => m
const money = (v: number, cur: string) => formatIncomeAmount(v, cur, locale.value)
const hoursText = (h: number) => new Intl.NumberFormat(locale.value, { maximumFractionDigits: 2 }).format(h)

async function load(y?: number) {
  try {
    report.value = await incomesReportRead(api, y || undefined)
    year.value = report.value.year
    state.value = 'ready'
  } catch (e) {
    state.value = (e as { status?: number })?.status === 403 ? 'forbidden' : 'error'
  }
}

/* in the browser only: the prerendered page is the loading line */
const access = useAccessStore()
onMounted(async () => {
  /* a reader /v1/view/me names not the owner gets the line, no request */
  if (!ownerReadable(await gateMe(access))) {
    state.value = 'forbidden'
    return
  }
  await load()
})
</script>

<style scoped>
.reporting-incomes { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.inc-error { color: var(--color-danger); margin: 0; }
.inc-year { display: inline-flex; align-items: center; gap: 8px; }
.inc-year select {
  font: inherit;
  min-height: 32px;
  padding: 4px 8px;
  color: inherit;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
}
@media (max-width: 820px) {
  .inc-year select { min-height: var(--tap, 44px); }
}
.inc-scroll { overflow-x: auto; min-width: 0; }
.inc-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.inc-table th, .inc-table td { padding: 6px 10px; border-bottom: 1px solid var(--color-border); text-align: start; white-space: nowrap; }
.inc-table thead th { font-weight: 600; }
.inc-table .num { text-align: end; font-variant-numeric: tabular-nums; }
.inc-gap td { color: var(--color-muted); }
.inc-total th, .inc-total td { font-weight: 600; border-top: 2px solid var(--color-border); }
/* a phone keeps the month, hours, net and total; the invoice number, the
   dates and the VAT (total - net) wait for a wider screen */
@media (max-width: 600px) {
  .inc-table { font-size: 0.8125rem; }
  .inc-table th, .inc-table td { padding: 6px 4px; }
  .inc-table .inc-opt { display: none; }
}
</style>
