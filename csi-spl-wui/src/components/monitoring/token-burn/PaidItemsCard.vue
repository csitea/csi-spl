<!-- Spec 140 3.8 (SPL-2567, owner HUM-10, t1 e8ae0aad msg 9f549412: "I
     should report the paid subscriptions and you would calculate the price
     per token"): the Tokens page's Paid card. The operator's paid items
     (GET/POST/PATCH/DELETE /v1/operator/fleet-tokens/paid) with add, edit
     and delete, and the effective price per token per vendor beside the
     list price (GET .../effective). Expenses -> AI costs mounts it (SPL-4382;
     the Tokens page did before) only for an admin of the operator
     workspace; a 403 here too draws nothing. Read
     once on open and after each change, never polled (the hub's read spans
     whole paid periods). -->
<template>
  <section v-if="state !== 'forbidden'" class="tk-section pd-card" data-test="paid-card">
    <div class="pd-head">
      <h3>{{ t('monitoring.tokens.paid.title') }}</h3>
      <button v-if="!form && !readonly" type="button" class="btn" data-test="paid-add" @click="openForm(null)">{{ t('monitoring.tokens.paid.add') }}</button>
    </div>
    <p class="muted pd-intro">{{ t('monitoring.tokens.paid.intro') }}</p>
    <p v-if="state === 'loading'" class="muted" data-test="paid-loading">{{ t('monitoring.tokens.paid.loading') }}</p>
    <p v-else-if="state === 'error'" class="pd-error" data-test="paid-error">
      {{ t('monitoring.tokens.paid.error') }}
      <button type="button" class="btn" @click="load()">{{ t('monitoring.tokens.retry') }}</button>
    </p>
    <p v-if="actionError" class="pd-error" role="alert" data-test="paid-action-error">{{ t('monitoring.tokens.paid.refused', { why: actionError }) }}</p>

    <PaidItemForm v-if="form" :key="form.key" :initial="form.initial" :editing="Boolean(form.id)" :currencies="currencies" :busy="busy" :refused="refused" @save="save" @cancel="closeForm" />

    <template v-if="state === 'ok'">
      <p v-if="!items.length" class="muted" data-test="paid-empty">{{ t('monitoring.tokens.paid.empty') }}</p>
      <template v-else>
        <div class="pd-tools">
          <span v-if="filtered" class="muted" role="status" data-test="paid-shown">{{ t('expenses.entries.shown', { n: rows.length, total: items.length }) }}</span>
          <button type="button" class="btn ghost" :disabled="!filtered" data-test="paid-filter-clear" @click="clearFilters()">{{ t('issues.filter_clear') }}</button>
        </div>
        <div class="tk-table-wrap">
          <table class="tk-table" data-test="paid-items">
            <thead>
              <tr>
                <th v-for="c in columns" :key="c.col" scope="col" :class="c.cls" :aria-sort="c.sorts ? ariaSort(c.col) : undefined">
                  <SheetSortButton v-if="c.sorts" :col="c.col" :name="c.name" :sort="sort" :test="'paid-sort-' + c.col" @sort="toggleSort" />
                  <template v-else>{{ c.name }}</template>
                </th>
                <th scope="col">{{ t('monitoring.tokens.paid.col_note') }}</th>
                <th v-if="!readonly" scope="col"><span class="pd-sr">{{ t('monitoring.tokens.paid.col_actions') }}</span></th>
              </tr>
              <tr class="pd-frow" data-test="paid-filters">
                <th>
                  <input v-model="filters.text" type="search" data-test="paid-filter-text" :placeholder="t('expenses.entries.filter_text')" :aria-label="t('expenses.entries.filter_text')">
                </th>
                <th>
                  <select v-model="filters.vendor" data-test="paid-filter-vendor" :aria-label="t('monitoring.tokens.col_vendor')">
                    <option value="">{{ t('monitoring.tokens.col_vendor') }}: {{ t('issues.filter_all') }}</option>
                    <option v-for="v in choices.vendor" :key="v" :value="v">{{ kindLabel(v) }}</option>
                  </select>
                </th>
                <th />
                <th colspan="3">
                  <select v-model="filters.currency" data-test="paid-filter-currency" :aria-label="t('expenses.entries.filter_currency')">
                    <option value="">{{ t('expenses.entries.filter_currency') }}: {{ t('issues.filter_all') }}</option>
                    <option v-for="c in choices.currency" :key="c" :value="c">{{ c }}</option>
                  </select>
                </th>
                <th />
                <th>
                  <select v-model="filters.period" data-test="paid-filter-period" :aria-label="t('monitoring.tokens.paid.col_period')">
                    <option value="">{{ t('monitoring.tokens.paid.col_period') }}: {{ t('issues.filter_all') }}</option>
                    <option v-for="m in choices.period" :key="m" :value="m">{{ m }}</option>
                  </select>
                </th>
                <th :colspan="readonly ? 1 : 2" />
              </tr>
            </thead>
            <tbody>
              <tr v-if="!rows.length">
                <td :colspan="readonly ? 9 : 10" class="muted" data-test="paid-no-match">{{ t('expenses.entries.no_match') }}</td>
              </tr>
              <tr v-for="it in rows" :key="it.id" data-test="paid-item-row" :data-id="it.id" :data-vendor="it.vendor">
                <th scope="row" data-test="paid-item-plan">{{ it.planLabel }}</th>
                <td :data-label="t('monitoring.tokens.col_vendor')">{{ kindLabel(it.vendor) }}</td>
                <td :data-label="t('monitoring.tokens.paid.col_kind')">{{ t('monitoring.tokens.paid.kind_' + it.kind) }}</td>
                <td class="num" :data-label="t('monitoring.tokens.paid.col_amount')" data-test="paid-item-amount">{{ fmtMoney(it.amount, it.currency, locale) }}</td>
                <td
                  v-for="cur in CURS"
                  :key="cur"
                  class="num"
                  :data-label="t('expenses.entries.col_amount_in', { currency: cur })"
                  :data-test="'paid-item-' + cur.toLowerCase()"
                  :data-converted="moneyCell(it, cur).converted || undefined"
                  :title="cellTitle(it, cur)"
                >{{ cellText(it, cur) }}</td>
                <td class="num" :data-label="t('monitoring.tokens.paid.col_quantity')">{{ it.quantity }}</td>
                <td :data-label="t('monitoring.tokens.paid.col_period')" data-test="paid-item-period">{{ t('monitoring.tokens.paid.period', { start: it.periodStart, end: it.periodEnd }) }}</td>
                <td class="pd-note" :data-label="t('monitoring.tokens.paid.col_note')">{{ it.note }}</td>
                <td v-if="!readonly" class="pd-row-actions">
                  <template v-if="confirming === it.id">
                    <span>{{ t('monitoring.tokens.paid.confirm_delete') }}</span>
                    <button type="button" class="btn danger" :disabled="busy" data-test="paid-delete-yes" @click="remove(it.id)">{{ t('monitoring.tokens.paid.delete') }}</button>
                    <button type="button" class="btn" :disabled="busy" data-test="paid-delete-no" @click="confirming = ''">{{ t('monitoring.tokens.paid.cancel') }}</button>
                  </template>
                  <template v-else>
                    <button type="button" class="btn" :disabled="busy" data-test="paid-edit" @click="openForm(it)">{{ t('monitoring.tokens.paid.edit') }}</button>
                    <button type="button" class="btn" :disabled="busy" data-test="paid-delete" @click="confirming = it.id">{{ t('monitoring.tokens.paid.delete') }}</button>
                  </template>
                </td>
              </tr>
            </tbody>
            <tfoot v-if="rows.length">
              <tr data-test="paid-total">
                <th scope="row" colspan="4">{{ t('expenses.entries.total') }}</th>
                <template v-if="totals.usd !== null && totals.eur !== null">
                  <td class="num" :data-label="t('expenses.entries.col_amount_in', { currency: 'USD' })" data-test="paid-total-usd">{{ fmtMoney(totals.usd, 'USD', locale) }}</td>
                  <td class="num" :data-label="t('expenses.entries.col_amount_in', { currency: 'EUR' })" data-test="paid-total-eur">{{ fmtMoney(totals.eur, 'EUR', locale) }}</td>
                </template>
                <td v-else colspan="2" class="muted" data-test="paid-total-none">{{ t('expenses.entries.total_no_rate') }}</td>
                <td :colspan="readonly ? 3 : 4" />
              </tr>
            </tfoot>
          </table>
        </div>
      </template>
      <EffectivePriceTable v-if="effective" :view="effective" />
      <p v-else-if="effectiveFailed" class="pd-error" data-test="paid-effective-error">{{ t('monitoring.tokens.paid.effective_error') }}</p>
    </template>
  </section>
</template>

<script setup lang="ts">
/* readonly (SPL-5181): the operator's product owner reads the list, no add, edit or delete */
defineProps<{ readonly?: boolean }>()
import { useSpoolApi } from '~/composables/useSpoolApi'
import { fmtMoney } from '~/utils/monitoring-tokens.mjs'
import { cycleSort } from '~/utils/sheet-sort.mjs'
import {
  emptyPaidForm, filterPaidItems, moneyCell, PAID_COLUMNS, PAID_NO_FILTER, paidBody, paidCurrencies, paidEffectiveOf, paidFilterChoices,
  paidFormOf, paidItemsFiltered, paidItemsOf, paidTotals, sortPaidItems, sortPaidRows,
} from '~/utils/monitoring-paid.mjs'
import PaidItemForm from './PaidItemForm.vue'
import EffectivePriceTable from './EffectivePriceTable.vue'

type PaidForm = ReturnType<typeof emptyPaidForm>
type PaidItem = ReturnType<typeof paidItemsOf>[number]
/* the lazy client's one paid method (spool-client-lazy.mjs fleetPaid): list | create | patch | delete | effective */
type PaidApi = {
  fleetPaid: (op: 'list' | 'create' | 'patch' | 'delete' | 'effective', a?: unknown, b?: unknown) => Promise<unknown>
  getFxCurrencies: () => Promise<unknown>
}

const { t, te, locale } = useI18n({ useScope: 'global' })
const api = () => useSpoolApi() as unknown as PaidApi
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const items = ref<PaidItem[]>([])
const effective = ref<ReturnType<typeof paidEffectiveOf> | null>(null)
const effectiveFailed = ref(false)
const currencies = ref<string[]>(['USD'])
const form = ref<{ key: number, id: string, initial: PaidForm } | null>(null)
const busy = ref(false)
const refused = ref('')
const actionError = ref('')
const confirming = ref('')
let formSeq = 0

const kindLabel = (v: string) => {
  const k = 'agents.kinds.' + (v === 'agy' ? 'antigravity' : v)
  return te(k) ? t(k) : v
}
/* SPL-5198 (owner HUM-10, t1 965283be msg 382450e2): sort and filter as
   the Issues and Lanes sheets (SheetSortButton, cycleSort), each amount in
   USD and EUR at the rates of its period_start (the hub's usd_micros /
   eur_micros), a converted one marked ≈, none as a dash; the total counts
   amount times quantity */
const CURS = ['USD', 'EUR'] as const
const COLUMN_KEYS: Record<string, string> = {
  plan: 'monitoring.tokens.paid.col_plan',
  vendor: 'monitoring.tokens.col_vendor',
  kind: 'monitoring.tokens.paid.col_kind',
  quantity: 'monitoring.tokens.paid.col_quantity',
  period: 'monitoring.tokens.paid.col_period',
}
const columns = computed(() => {
  const cols = PAID_COLUMNS.map((col: string) => ({
    col,
    name: COLUMN_KEYS[col] ? t(COLUMN_KEYS[col]!) : t('expenses.entries.col_amount_in', { currency: col.toUpperCase() }),
    cls: col === 'usd' || col === 'eur' || col === 'quantity' ? 'num' : undefined,
    sorts: true,
  }))
  /* the price as entered, in its own currency: no sort across currencies */
  cols.splice(cols.findIndex((c) => c.col === 'usd'), 0, { col: 'amount', name: t('monitoring.tokens.paid.col_amount'), cls: 'num', sorts: false })
  return cols
})
const sort = ref<{ col: string, dir: string }>({ col: '', dir: '' })
const toggleSort = (col: string) => { sort.value = cycleSort(col, sort.value, PAID_COLUMNS) }
const ariaSort = (col: string) => (sort.value.col === col ? (sort.value.dir === 'asc' ? 'ascending' : 'descending') : 'none')
const filters = reactive({ ...PAID_NO_FILTER })
const filtered = computed(() => paidItemsFiltered(filters))
const clearFilters = () => { Object.assign(filters, PAID_NO_FILTER) }
const choices = computed(() => paidFilterChoices(items.value))
const rows = computed(() => sortPaidRows(filterPaidItems(items.value, filters), sort.value))
const totals = computed(() => paidTotals(rows.value))
function cellText(it: PaidItem, cur: 'USD' | 'EUR') {
  const c = moneyCell(it, cur)
  return c.amount === null ? '—' : (c.converted ? '≈ ' : '') + fmtMoney(c.amount, cur, locale.value)
}
function cellTitle(it: PaidItem, cur: 'USD' | 'EUR') {
  const c = moneyCell(it, cur)
  if (c.none) return t('expenses.entries.no_rate', { currency: c.missing })
  return c.converted ? t('expenses.entries.converted', { currency: it.currency, day: c.day }) : undefined
}

/* the hub's own words when it refuses: its detail, else its token */
const hubWhy = (e: unknown) => {
  const err = e as { detail?: string, token?: string, message?: string }
  return String((err && (err.detail || err.token || err.message)) || '')
}

async function loadEffective() {
  try {
    effective.value = paidEffectiveOf(await api().fleetPaid('effective'))
    effectiveFailed.value = false
  } catch {
    effective.value = null
    effectiveFailed.value = true
  }
}

async function load() {
  try {
    items.value = sortPaidItems(paidItemsOf(await api().fleetPaid('list')))
    state.value = 'ok'
  } catch (e) {
    state.value = (e as { status?: number })?.status === 403 ? 'forbidden' : 'error'
    return
  }
  await loadEffective()
}

function openForm(it: PaidItem | null) {
  refused.value = ''
  actionError.value = ''
  confirming.value = ''
  form.value = { key: ++formSeq, id: it ? it.id : '', initial: it ? paidFormOf(it) : emptyPaidForm() }
}

function closeForm() {
  form.value = null
  refused.value = ''
}

async function save(f: PaidForm) {
  if (!form.value) return
  busy.value = true
  refused.value = ''
  try {
    const id = form.value.id
    if (id) await api().fleetPaid('patch', id, paidBody(f))
    else await api().fleetPaid('create', paidBody(f))
    form.value = null
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
    await api().fleetPaid('delete', id)
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

<style scoped src="./token-burn.css"></style>
<style scoped>
.pd-card { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.pd-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px; }
.pd-head h3 { margin: 0; }
.pd-intro { margin: 0; font-size: 0.8125rem; }
.pd-error { margin: 0; color: var(--color-danger); display: flex; flex-wrap: wrap; align-items: center; gap: 8px; overflow-wrap: anywhere; }
.pd-note { overflow-wrap: anywhere; max-width: 20rem; }
.pd-row-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; white-space: nowrap; }
.pd-tools { display: flex; flex-wrap: wrap; align-items: center; justify-content: flex-end; gap: 8px; }
.pd-frow th { font-weight: normal; padding-top: 2px; }
/* SPL-5198: a phone keeps the sort names and the filter row (token-burn.css hides a .tk-table head under 601 px) as the rows' 2-column grid */
@media (max-width: 600px) {
  .pd-card .tk-table thead { display: block; }
  .pd-card .tk-table thead th:empty { display: none; }
}
.pd-frow select, .pd-frow input { width: 100%; min-width: 5rem; max-width: 16rem; font: inherit; box-sizing: border-box; }
tfoot th, tfoot td { font-weight: 600; border-bottom: 0; }
.pd-sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
</style>
