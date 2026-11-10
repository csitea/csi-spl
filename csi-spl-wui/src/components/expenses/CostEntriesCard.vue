<!-- Spec 143 expenses-cost-entries.md (SPL-4382; owner HUM-10, t1 4f48f878, msg
     b0ccc0aa: "different types for the INSERTION"): one tab's hand-entered
     costs, Cloud infra or HR. The list, Add and Delete over the hub's
     /v1/operator/cost-entries, one type per tab; there is no edit route, a
     wrong entry is deleted and entered again. Read once on open and after each
     change. A 403 draws nothing. Loaded with its tab only (utils/cost-entries.mjs). -->
<template>
  <section v-if="state !== 'forbidden'" class="tk-section ce-card" :data-test="'expenses-' + type">
    <div class="ce-head">
      <h3>{{ t('expenses.tab.' + type) }}</h3>
      <button v-if="!adding && !readonly" type="button" class="btn" data-test="cost-add" @click="openForm()">{{ t('expenses.entries.add') }}</button>
    </div>
    <p class="muted ce-intro">{{ t('expenses.entries.intro_' + type) }}</p>
    <p v-if="state === 'loading'" class="muted" data-test="cost-loading">{{ t('expenses.entries.loading') }}</p>
    <p v-else-if="state === 'error'" class="ce-error" data-test="cost-error">
      {{ t('expenses.entries.error') }}
      <button type="button" class="btn" @click="load()">{{ t('monitoring.tokens.retry') }}</button>
    </p>
    <p v-if="actionError" class="ce-error" role="alert" data-test="cost-action-error">{{ t('monitoring.tokens.paid.refused', { why: actionError }) }}</p>

    <form v-if="adding" class="ce-form" data-test="cost-form" novalidate @submit.prevent="submit">
      <div class="ce-grid">
        <label class="ce-wide">
          <span>{{ t('expenses.entries.col_label_' + type) }}</span>
          <input v-model="f.label" type="text" maxlength="100" data-test="cost-f-label">
        </label>
        <label>
          <span>{{ t('expenses.entries.col_amount') }}</span>
          <input v-model="f.amount" type="number" min="0" step="0.01" inputmode="decimal" data-test="cost-f-amount">
        </label>
        <label>
          <span>{{ t('monitoring.tokens.paid.field_currency') }}</span>
          <select v-model="f.currency" data-test="cost-f-currency">
            <option v-for="c in currencies" :key="c" :value="c">{{ c }}</option>
          </select>
        </label>
        <label>
          <span>{{ t('expenses.entries.col_period') }}</span>
          <input v-model="f.period" type="month" data-test="cost-f-period">
        </label>
        <label class="ce-wide">
          <span>{{ t('monitoring.tokens.paid.col_note') }}</span>
          <textarea v-model="f.note" rows="2" maxlength="2000" data-test="cost-f-note" />
        </label>
      </div>
      <p v-if="problem" class="ce-error" role="alert" data-test="cost-form-error">{{ t('expenses.entries.' + problem) }}</p>
      <p v-else-if="refused" class="ce-error" role="alert" data-test="cost-form-refused">{{ t('monitoring.tokens.paid.refused', { why: refused }) }}</p>
      <div class="ce-actions">
        <button type="submit" class="btn primary" :disabled="busy" data-test="cost-save">{{ t('monitoring.tokens.paid.save') }}</button>
        <button type="button" class="btn" :disabled="busy" data-test="cost-cancel" @click="adding = false">{{ t('monitoring.tokens.paid.cancel') }}</button>
      </div>
    </form>

    <template v-if="state === 'ok'">
      <p v-if="!entries.length" class="muted" data-test="cost-empty">{{ t('expenses.entries.empty') }}</p>
      <template v-else>
        <div class="ce-tools">
          <span v-if="filtered" class="muted" role="status" data-test="cost-shown">{{ t('expenses.entries.shown', { n: rows.length, total: entries.length }) }}</span>
          <button type="button" class="btn ghost" :disabled="!filtered" data-test="cost-filter-clear" @click="clearFilters()">{{ t('issues.filter_clear') }}</button>
        </div>
        <div class="tk-table-wrap">
          <table class="tk-table" data-test="cost-entries">
            <thead>
              <tr>
                <th v-for="c in columns" :key="c.col" scope="col" :class="c.cls" :aria-sort="c.sorts ? ariaSort(c.col) : undefined">
                  <SheetSortButton v-if="c.sorts" :col="c.col" :name="c.name" :sort="sort" :test="'cost-sort-' + c.col" @sort="toggleSort" />
                  <template v-else>{{ c.name }}</template>
                </th>
                <th scope="col">{{ t('monitoring.tokens.paid.col_note') }}</th>
                <th v-if="!readonly" scope="col"><span class="ce-sr">{{ t('monitoring.tokens.paid.col_actions') }}</span></th>
              </tr>
              <tr class="ce-frow" data-test="cost-filters">
                <th>
                  <input v-model="filters.text" type="search" data-test="cost-filter-text" :placeholder="t('expenses.entries.filter_text')" :aria-label="t('expenses.entries.filter_text')">
                </th>
                <th colspan="3">
                  <select v-model="filters.currency" data-test="cost-filter-currency" :aria-label="t('expenses.entries.filter_currency')">
                    <option value="">{{ t('expenses.entries.filter_currency') }}: {{ t('issues.filter_all') }}</option>
                    <option v-for="c in choices.currency" :key="c" :value="c">{{ c }}</option>
                  </select>
                </th>
                <th>
                  <select v-model="filters.period" data-test="cost-filter-period" :aria-label="t('expenses.entries.col_period')">
                    <option value="">{{ t('expenses.entries.col_period') }}: {{ t('issues.filter_all') }}</option>
                    <option v-for="m in choices.period" :key="m" :value="m">{{ m }}</option>
                  </select>
                </th>
                <th :colspan="readonly ? 1 : 2" />
              </tr>
            </thead>
            <tbody>
              <tr v-if="!rows.length">
                <td :colspan="readonly ? 6 : 7" class="muted" data-test="cost-no-match">{{ t('expenses.entries.no_match') }}</td>
              </tr>
              <tr v-for="e in rows" :key="e.id" data-test="cost-row" :data-id="e.id">
                <th scope="row" class="ce-text" data-test="cost-row-label">{{ e.label }}</th>
                <td class="num" :data-label="t('expenses.entries.col_amount')" data-test="cost-row-amount">{{ fmtMoney(e.amount, e.currency, locale) }}</td>
                <td
                  v-for="cur in CURS"
                  :key="cur"
                  class="num"
                  :data-label="t('expenses.entries.col_amount_in', { currency: cur })"
                  :data-test="'cost-row-' + cur.toLowerCase()"
                  :data-converted="cell(e, cur).converted || undefined"
                  :title="cellTitle(e, cur)"
                >{{ cellText(e, cur) }}</td>
                <td :data-label="t('expenses.entries.col_period')" data-test="cost-row-period">{{ e.period }}</td>
                <td class="ce-text" :data-label="t('monitoring.tokens.paid.col_note')">{{ e.note }}</td>
                <td v-if="!readonly" class="ce-row-actions">
                  <template v-if="confirming === e.id">
                    <span>{{ t('expenses.entries.confirm_delete') }}</span>
                    <button type="button" class="btn danger" :disabled="busy" data-test="cost-delete-yes" @click="remove(e.id)">{{ t('monitoring.tokens.paid.delete') }}</button>
                    <button type="button" class="btn" :disabled="busy" data-test="cost-delete-no" @click="confirming = ''">{{ t('monitoring.tokens.paid.cancel') }}</button>
                  </template>
                  <button v-else type="button" class="btn" :disabled="busy" data-test="cost-delete" @click="confirming = e.id">{{ t('monitoring.tokens.paid.delete') }}</button>
                </td>
              </tr>
            </tbody>
            <tfoot v-if="rows.length">
              <tr data-test="cost-total">
                <th scope="row" colspan="2">{{ t('expenses.entries.total') }}</th>
                <template v-if="totals.usd !== null && totals.eur !== null">
                  <td class="num" :data-label="t('expenses.entries.col_amount_in', { currency: 'USD' })" data-test="cost-total-usd">{{ fmtMoney(totals.usd, 'USD', locale) }}</td>
                  <td class="num" :data-label="t('expenses.entries.col_amount_in', { currency: 'EUR' })" data-test="cost-total-eur">{{ fmtMoney(totals.eur, 'EUR', locale) }}</td>
                </template>
                <td v-else colspan="2" class="muted" data-test="cost-total-none">{{ t('expenses.entries.total_no_rate') }}</td>
                <td :colspan="readonly ? 2 : 3" />
              </tr>
            </tfoot>
          </table>
        </div>
      </template>
    </template>
  </section>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { fmtMoney } from '~/utils/monitoring-tokens.mjs'
import { paidCurrencies } from '~/utils/monitoring-paid.mjs'
import { cycleSort } from '~/utils/sheet-sort.mjs'
import {
  checkCostEntryForm, COST_ENTRY_COLUMNS, COST_ENTRY_NO_FILTER, costEntriesFiltered, costEntriesOf, costEntryBody, costEntryCell,
  costEntryFilterChoices, costEntryTotals, emptyCostEntryForm, filterCostEntries, sortCostEntries,
} from '~/utils/cost-entries.mjs'

/* readonly (SPL-5181): the operator's product owner reads the list, no add or delete */
const props = defineProps<{ type: 'cloud' | 'hr', readonly?: boolean }>()
/* the lazy client's one paid method (spool-client-lazy.mjs fleetPaid): no new stub in the initial chunk */
type CostApi = {
  fleetPaid: (op: 'entries' | 'entry_create' | 'entry_delete', a?: unknown) => Promise<unknown>
  getFxCurrencies: () => Promise<unknown>
}

const { t, locale } = useI18n({ useScope: 'global' })
const api = () => useSpoolApi() as unknown as CostApi
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const entries = ref<ReturnType<typeof costEntriesOf>>([])
const currencies = ref<string[]>(['USD'])
const adding = ref(false)
const f = reactive(emptyCostEntryForm())
const problem = ref('')
const refused = ref('')
const actionError = ref('')
const confirming = ref('')
const busy = ref(false)

/* SPL-5198 (owner HUM-10, t1 965283be msg 382450e2): sort and filter as
   the Issues and Lanes sheets (SheetSortButton, cycleSort), each amount in
   USD and EUR (the hub's usd_micros / eur_micros) next to the amount as
   entered, a converted one marked ≈ with the day of its rate (usd_rate_day /
   eur_rate_day), none as a dash; the total of the shown rows */
const CURS = ['USD', 'EUR'] as const
type Row = ReturnType<typeof costEntriesOf>[number]
const columns = computed(() => {
  const cols = COST_ENTRY_COLUMNS.map((col: string) => ({
    col,
    name: col === 'label' ? t('expenses.entries.col_label_' + props.type) : col === 'period' ? t('expenses.entries.col_period') : t('expenses.entries.col_amount_in', { currency: col.toUpperCase() }),
    cls: col === 'usd' || col === 'eur' ? 'num' : undefined,
    sorts: true,
  }))
  /* the amount as entered, in its own currency: no sort across currencies */
  cols.splice(1, 0, { col: 'amount', name: t('expenses.entries.col_amount'), cls: 'num', sorts: false })
  return cols
})
const sort = ref<{ col: string, dir: string }>({ col: '', dir: '' })
const toggleSort = (col: string) => { sort.value = cycleSort(col, sort.value, COST_ENTRY_COLUMNS) }
const ariaSort = (col: string) => (sort.value.col === col ? (sort.value.dir === 'asc' ? 'ascending' : 'descending') : 'none')
const filters = reactive({ ...COST_ENTRY_NO_FILTER })
const filtered = computed(() => costEntriesFiltered(filters))
const clearFilters = () => { Object.assign(filters, COST_ENTRY_NO_FILTER) }
const choices = computed(() => costEntryFilterChoices(entries.value))
const rows = computed(() => sortCostEntries(filterCostEntries(entries.value, filters), sort.value))
const totals = computed(() => costEntryTotals(rows.value))
const cell = (e: Row, cur: 'USD' | 'EUR') => costEntryCell(e, cur)
function cellText(e: Row, cur: 'USD' | 'EUR') {
  const c = cell(e, cur)
  return c.amount === null ? '—' : (c.converted ? '≈ ' : '') + fmtMoney(c.amount, cur, locale.value)
}
function cellTitle(e: Row, cur: 'USD' | 'EUR') {
  const c = cell(e, cur)
  if (c.none) return t('expenses.entries.no_rate', { currency: c.missing })
  return c.converted ? t('expenses.entries.converted', { currency: e.currency, day: c.day }) : undefined
}

/* the hub's own words when it refuses: its detail, else its token */
const hubWhy = (e: unknown) => {
  const err = e as { detail?: string, token?: string, message?: string }
  return String((err && (err.detail || err.token || err.message)) || '')
}

async function load() {
  try {
    entries.value = costEntriesOf(await api().fleetPaid('entries', props.type))
    state.value = 'ok'
  } catch (e) {
    state.value = (e as { status?: number })?.status === 403 ? 'forbidden' : 'error'
  }
}

function openForm() {
  Object.assign(f, emptyCostEntryForm())
  problem.value = ''
  refused.value = ''
  actionError.value = ''
  confirming.value = ''
  adding.value = true
}

async function submit() {
  refused.value = ''
  problem.value = checkCostEntryForm(f, currencies.value)
  if (problem.value) return
  busy.value = true
  try {
    await api().fleetPaid('entry_create', costEntryBody(props.type, f))
    adding.value = false
    await load()
  } catch (e) {
    refused.value = hubWhy(e)
  } finally {
    busy.value = false
  }
}

async function remove(id: string) {
  busy.value = true
  actionError.value = ''
  try {
    await api().fleetPaid('entry_delete', id)
    confirming.value = ''
    await load()
  } catch (e) {
    actionError.value = hubWhy(e)
  } finally {
    busy.value = false
  }
}

onMounted(async () => {
  void api().getFxCurrencies().then((b) => { currencies.value = paidCurrencies(b) }, () => { currencies.value = ['USD'] })
  await load()
})
</script>

<style scoped src="../monitoring/token-burn/token-burn.css"></style>
<style scoped>
.ce-card { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.ce-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px; }
.ce-head h3 { margin: 0; }
.ce-intro { margin: 0; font-size: 0.8125rem; }
.ce-error { margin: 0; color: var(--color-danger); display: flex; flex-wrap: wrap; align-items: center; gap: 8px; overflow-wrap: anywhere; }
.ce-text { overflow-wrap: anywhere; max-width: 20rem; }
.ce-row-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; white-space: nowrap; }
.ce-sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
.ce-form { display: flex; flex-direction: column; gap: 8px; padding: 10px 12px; border: 1px solid var(--color-border); border-radius: var(--radius-md); }
.ce-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(11rem, 1fr)); gap: 8px 12px; }
.ce-grid label { display: flex; flex-direction: column; gap: 2px; min-width: 0; font-size: 0.875rem; }
.ce-grid label > span { color: var(--color-muted); font-size: 0.8125rem; }
.ce-grid input, .ce-grid select, .ce-grid textarea { min-width: 0; width: 100%; box-sizing: border-box; }
.ce-wide { grid-column: 1 / -1; }
.ce-actions { display: flex; flex-wrap: wrap; gap: 8px; }
.ce-tools { display: flex; flex-wrap: wrap; align-items: center; justify-content: flex-end; gap: 8px; }
.ce-frow th { font-weight: normal; padding-top: 2px; }
/* SPL-5198: a phone keeps the sort names and the filter row (token-burn.css hides a .tk-table head under 601 px) as the rows' 2-column grid */
@media (max-width: 600px) {
  .ce-card .tk-table thead { display: block; }
  .ce-card .tk-table thead th:empty { display: none; }
}
.ce-frow select, .ce-frow input { width: 100%; min-width: 5rem; max-width: 16rem; font: inherit; box-sizing: border-box; }
tfoot th, tfoot td { font-weight: 600; border-bottom: 0; }
</style>
