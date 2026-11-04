<!-- Spec 125 row B7 (SPL-4741, case C-NVS-7; owner HUM-10, topic fc0119cd,
     constraints C2, C7, C8): Reporting -> Finance, the screen of every
     person of the Netvisor workspace (C7 as rewritten, SPL-4792; owner msg
     cfa78746). The Netvisor owner's newest snapshot as the hub keeps it (B5):
     the month-end cash forecast card and its items, the newest bank voucher
     date, "Refresh now" (asks the main-box sync for a new fetch), the card
     costs by vendor, cost type or cost centre (spec-123 vendors left out,
     owner answer Q4 = EXCL) and the bookkeeping-account settings form (Q2:
     the owner types the account numbers here). "Refresh now" and the form
     are the owner's alone (the views' reader_is_owner); the hub answers the
     views 403 to an agent seat or an act-as clone and 404 in every other
     workspace: this page then shows that line and no figure. -->
<template>
  <div class="reporting-finance" data-test="reporting-finance">
    <p v-if="state === 'loading'" class="muted" role="status" data-test="finance-loading">{{ t('reporting.finance.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="muted" role="alert" data-test="finance-forbidden">{{ t('reporting.finance.forbidden') }}</p>
    <p v-else-if="state === 'error'" class="fin-error" role="alert" data-test="finance-error">{{ t('reporting.finance.error') }}</p>
    <template v-else>
      <div class="fin-head" data-test="finance-head">
        <span class="fin-badge" data-test="finance-env">{{ t('reporting.finance.env.' + (env === 'prd' ? 'prd' : 'test')) }}</span>
        <span v-if="snapshot" class="fin-badge fin-badge--voucher" data-test="finance-voucher" :data-date="snapshot.newest_bank_voucher_date">
          {{ snapshot.newest_bank_voucher_date ? t('reporting.finance.voucher', { date: snapshot.newest_bank_voucher_date }) : t('reporting.finance.voucher_none') }}
        </span>
        <span v-if="snapshot" class="muted" data-test="finance-as-of">{{ t('reporting.finance.as_of', { date: snapshot.as_of, time: isoDateTime(snapshot.fetched_at) }) }}</span>
        <button v-if="isOwner" type="button" class="btn" :disabled="refreshing" data-test="finance-refresh" @click="refresh">{{ t('reporting.finance.refresh') }}</button>
        <span v-if="refreshAt" class="muted" role="status" data-test="finance-refresh-requested">{{ t('reporting.finance.refresh_requested', { time: isoDateTime(refreshAt) }) }}</span>
        <span v-if="refreshFailed" class="fin-error" role="alert" data-test="finance-refresh-error">{{ t('reporting.finance.refresh_error') }}</span>
      </div>

      <p v-if="!snapshot" class="muted" data-test="finance-no-snapshot">{{ t(isOwner ? 'reporting.finance.no_snapshot' : 'reporting.finance.no_snapshot_member') }}</p>
      <template v-else>
        <section class="fin-card" :aria-label="t('reporting.finance.forecast.title')" data-test="finance-forecast">
          <h3 class="fin-title">{{ t('reporting.finance.forecast.title') }}</h3>
          <p class="fin-month-end" data-test="finance-month-end">
            {{ t('reporting.finance.forecast.month_end', { date: snapshot.month_end }) }}
            <strong v-for="tot in forecast.totals" :key="tot.currency" class="fin-total" data-test="finance-total" :data-currency="tot.currency">{{ money(tot.cents, tot.currency) }}</strong>
          </p>
          <ul class="fin-cats" :aria-label="t('reporting.finance.forecast.by_category')" data-test="finance-categories">
            <li v-for="c in forecast.categories" :key="c.category + c.currency" data-test="finance-category" :data-category="c.category">
              <span>{{ t('reporting.finance.category.' + c.category) }}</span>
              <span class="num">{{ money(c.cents, c.currency) }}</span>
            </li>
          </ul>
          <p v-if="!forecast.rows.length" class="muted" data-test="finance-items-empty">{{ t('reporting.finance.forecast.empty') }}</p>
          <div v-else class="fin-table-wrap">
            <table class="fin-table" :aria-label="t('reporting.finance.forecast.items_label')" data-test="finance-items">
              <thead>
                <tr>
                  <th scope="col">{{ t('reporting.finance.forecast.col_category') }}</th>
                  <th scope="col">{{ t('reporting.finance.forecast.col_label') }}</th>
                  <th scope="col">{{ t('reporting.finance.forecast.col_due') }}</th>
                  <th scope="col">{{ t('reporting.finance.forecast.col_status') }}</th>
                  <th scope="col" class="num">{{ t('reporting.finance.forecast.col_amount') }}</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="it in forecast.rows" :key="it.item_no" data-test="finance-item" :data-category="it.category">
                  <td>{{ t('reporting.finance.category.' + it.category) }}</td>
                  <td class="fin-label">{{ it.label }}</td>
                  <td class="num" :data-label="t('reporting.finance.forecast.col_due')">{{ it.due_date }}</td>
                  <td :data-label="t('reporting.finance.forecast.col_status')">
                    <span v-if="it.overdue" class="fin-flag fin-flag--warn" data-test="finance-item-overdue">{{ t('reporting.finance.forecast.overdue') }}</span>
                    <span v-if="it.approved === true" class="fin-flag">{{ t('reporting.finance.forecast.approved') }}</span>
                    <span v-else-if="it.approved === false" class="fin-flag fin-flag--warn">{{ t('reporting.finance.forecast.unapproved') }}</span>
                  </td>
                  <td class="num" :data-label="t('reporting.finance.forecast.col_amount')">{{ money(it.signedCents, it.currency) }}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p v-if="forecast.skipped" class="muted" data-test="finance-items-skipped">{{ t('reporting.finance.forecast.skipped', { n: forecast.skipped }) }}</p>
        </section>

        <section class="fin-card" :aria-label="t('reporting.finance.costs.title')" data-test="finance-costs">
          <h3 class="fin-title">{{ t('reporting.finance.costs.title') }}</h3>
          <div class="fin-slices" role="group" :aria-label="t('reporting.finance.costs.slices_label')" data-test="finance-slices">
            <button
              v-for="s in FINANCE_SLICES"
              :key="s"
              type="button"
              class="btn ghost"
              :aria-pressed="slice === s ? 'true' : 'false'"
              :data-test="'finance-slice-' + s"
              @click="slice = s"
            >{{ t('reporting.finance.costs.slice_' + s) }}</button>
          </div>
          <p v-if="!costs.rows.length" class="muted" data-test="finance-costs-empty">{{ t('reporting.finance.costs.empty') }}</p>
          <div v-else class="fin-table-wrap">
            <table class="fin-table" data-test="finance-costs-table" :data-slice="slice">
              <thead>
                <tr>
                  <th scope="col">{{ t('reporting.finance.costs.col_month') }}</th>
                  <th scope="col">{{ t('reporting.finance.costs.slice_' + slice) }}</th>
                  <th scope="col" class="num">{{ t('reporting.finance.costs.col_lines') }}</th>
                  <th scope="col" class="num">{{ t('reporting.finance.costs.col_amount') }}</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="r in costs.rows" :key="r.month + r.name + r.currency" data-test="finance-cost-row">
                  <td>{{ r.month }}</td>
                  <td class="fin-label" data-test="finance-cost-group">{{ r.name || t('reporting.finance.costs.none') }}</td>
                  <td class="num" :data-label="t('reporting.finance.costs.col_lines')">{{ r.lines }}</td>
                  <td class="num" :data-label="t('reporting.finance.costs.col_amount')">{{ money(r.cents, r.currency) }}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p v-if="costs.excluded.lines" class="muted" data-test="finance-costs-excluded" :data-lines="costs.excluded.lines">
            {{ t('reporting.finance.costs.excluded', { n: costs.excluded.lines, amount: costs.excluded.totals.map((x) => money(x.cents, x.currency)).join(', ') }) }}
          </p>
        </section>
      </template>

      <FinanceSettings v-if="isOwner && settings" :settings="settings" :api="api" @saved="onSaved" />
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import FinanceSettings from '~/components/reporting/finance/FinanceSettings.vue'
import { isoDateTime } from '~/utils/date-iso.mjs'
import {
  FINANCE_SLICES,
  NETVISOR_CARD_COSTS_PATH,
  NETVISOR_FORECAST_PATH,
  NETVISOR_REFRESH_PATH,
  NETVISOR_SETTINGS_PATH,
  cardCostBreakdown,
  forecastSummary,
  formatCents,
  netvisorCall,
} from '~/utils/reporting-finance.mjs'

type Api = { mock?: boolean, base?: string }
type Snapshot = { as_of: string, month_end: string, newest_bank_voucher_date: string, fetched_at: string }
type Settings = { env?: string, vendor_exclusions?: string[] } & Record<string, unknown>
type View = { env?: string, snapshot?: Snapshot | null, items?: unknown[], lines?: unknown[], vendor_exclusions?: string[], refresh_requested_at?: string | null, reader_is_owner?: boolean }

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi() as unknown as Api

const state = ref<'loading' | 'ready' | 'forbidden' | 'error'>('loading')
const forecastView = ref<View | null>(null)
const costsView = ref<View | null>(null)
const settings = ref<Settings | null>(null)
const slice = ref<string>('vendor')
const refreshAt = ref<string | null>(null)
const refreshing = ref(false)
const refreshFailed = ref(false)

const isOwner = computed(() => forecastView.value?.reader_is_owner === true)
const env = computed(() => forecastView.value?.env || settings.value?.env || 'test')
const snapshot = computed(() => forecastView.value?.snapshot || null)
const forecast = computed(() => forecastSummary(forecastView.value))
const costs = computed(() => cardCostBreakdown(costsView.value, slice.value, settings.value?.vendor_exclusions || costsView.value?.vendor_exclusions || []))
const money = (cents: number, currency: string) => (currency ? `${formatCents(cents)} ${currency}` : formatCents(cents))

async function load() {
  /* the views first: their 403 / 404 is the door; the settings (the vendor
     exclusions and the form) only for the owner, so a member sends no read
     the hub refuses */
  const [f, c] = await Promise.all([
    netvisorCall(api, 'GET', NETVISOR_FORECAST_PATH) as Promise<View>,
    netvisorCall(api, 'GET', NETVISOR_CARD_COSTS_PATH) as Promise<View>,
  ])
  settings.value = f?.reader_is_owner === true ? await netvisorCall(api, 'GET', NETVISOR_SETTINGS_PATH) as Settings : null
  forecastView.value = f
  costsView.value = c
  refreshAt.value = f?.refresh_requested_at || null
}

async function refresh() {
  refreshing.value = true
  refreshFailed.value = false
  try {
    const out = await netvisorCall(api, 'POST', NETVISOR_REFRESH_PATH, {}) as { refresh_requested_at?: string | null }
    refreshAt.value = out?.refresh_requested_at || null
  } catch {
    refreshFailed.value = true
  } finally {
    refreshing.value = false
  }
}

/* a new env or exclusion list reads the views again */
async function onSaved(next: Settings) {
  settings.value = next
  try {
    await load()
  } catch {
    state.value = 'error'
  }
}

/* in the browser only: the prerendered page is the loading line */
onMounted(async () => {
  try {
    await load()
    state.value = 'ready'
  } catch (e) {
    const status = (e as { status?: number })?.status
    state.value = status === 403 || status === 404 || status === 401 ? 'forbidden' : 'error'
  }
})
</script>

<style scoped>
.reporting-finance { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.fin-error { color: var(--color-danger); margin: 0; }
.fin-head { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
.fin-badge { padding: 2px 10px; border: 1px solid var(--color-border); border-radius: var(--radius-pill); font-size: 0.875rem; white-space: nowrap; }
.fin-badge--voucher { font-weight: 600; }
.fin-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-width: 0;
  padding: 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
}
.fin-title { margin: 0; font-size: 1rem; font-weight: 600; }
.fin-month-end { margin: 0; display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 12px; }
.fin-total { font-size: 1rem; font-variant-numeric: tabular-nums; white-space: nowrap; }
.fin-cats { list-style: none; margin: 0; padding: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 220px), 1fr)); gap: 4px 16px; font-size: 0.875rem; }
.fin-cats li { display: flex; justify-content: space-between; gap: 8px; }
.fin-slices { display: flex; flex-wrap: wrap; gap: 6px; }
.fin-slices .btn[aria-pressed='true'] { font-weight: 600; border-color: var(--color-accent); }
.fin-table-wrap { overflow-x: auto; max-width: 100%; }
.fin-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.fin-table th, .fin-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
.fin-table .num { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
.fin-label { overflow-wrap: anywhere; }
.fin-flag { display: inline-block; margin-inline-end: 4px; padding: 0 6px; border: 1px solid var(--color-border); border-radius: var(--radius-pill); font-size: 0.75rem; white-space: nowrap; }
.fin-flag--warn { color: var(--color-warn); border-color: var(--color-warn); }
/* a phone: each row is a card, its figures labelled (no sideways scroll) */
@media (max-width: 600px) {
  .fin-table thead { display: none; }
  .fin-table tr { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 2px 12px; padding: 6px 0; border-bottom: 1px solid var(--color-border); }
  .fin-table th, .fin-table td { border-bottom: 0; padding: 0 4px; }
  .fin-table .num { text-align: start; }
  .fin-table [data-label]:not(:empty)::before { content: attr(data-label) ": "; color: var(--color-muted); }
}
</style>
