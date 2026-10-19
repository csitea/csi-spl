<!-- Spec 140 3.8 (SPL-2567, owner HUM-10, t1 e8ae0aad msg 9f549412: "I
     should report the paid subscriptions and you would calculate the price
     per token"): the Tokens page's Paid card. The operator's paid items
     (GET/POST/PATCH/DELETE /v1/operator/fleet-tokens/paid) with add, edit
     and delete, and the effective price per token per vendor beside the
     list price (GET .../effective). The Tokens page mounts it only for an
     admin of the operator workspace; a 403 here too draws nothing. Read
     once on open and after each change, never polled (the hub's read spans
     whole paid periods). -->
<template>
  <section v-if="state !== 'forbidden'" class="tk-section pd-card" data-test="paid-card">
    <div class="pd-head">
      <h3>{{ t('monitoring.tokens.paid.title') }}</h3>
      <button v-if="!form" type="button" class="btn" data-test="paid-add" @click="openForm(null)">{{ t('monitoring.tokens.paid.add') }}</button>
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
      <div v-else class="tk-table-wrap">
        <table class="tk-table" data-test="paid-items">
          <thead>
            <tr>
              <th scope="col">{{ t('monitoring.tokens.paid.col_plan') }}</th>
              <th scope="col">{{ t('monitoring.tokens.col_vendor') }}</th>
              <th scope="col">{{ t('monitoring.tokens.paid.col_kind') }}</th>
              <th scope="col" class="num">{{ t('monitoring.tokens.paid.col_amount') }}</th>
              <th scope="col" class="num">{{ t('monitoring.tokens.paid.col_quantity') }}</th>
              <th scope="col">{{ t('monitoring.tokens.paid.col_period') }}</th>
              <th scope="col">{{ t('monitoring.tokens.paid.col_note') }}</th>
              <th scope="col"><span class="pd-sr">{{ t('monitoring.tokens.paid.col_actions') }}</span></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="it in items" :key="it.id" data-test="paid-item-row" :data-id="it.id" :data-vendor="it.vendor">
              <th scope="row" data-test="paid-item-plan">{{ it.planLabel }}</th>
              <td :data-label="t('monitoring.tokens.col_vendor')">{{ kindLabel(it.vendor) }}</td>
              <td :data-label="t('monitoring.tokens.paid.col_kind')">{{ t('monitoring.tokens.paid.kind_' + it.kind) }}</td>
              <td class="num" :data-label="t('monitoring.tokens.paid.col_amount')" data-test="paid-item-amount">{{ fmtMoney(it.amount, it.currency, locale) }}</td>
              <td class="num" :data-label="t('monitoring.tokens.paid.col_quantity')">{{ it.quantity }}</td>
              <td :data-label="t('monitoring.tokens.paid.col_period')" data-test="paid-item-period">{{ t('monitoring.tokens.paid.period', { start: it.periodStart, end: it.periodEnd }) }}</td>
              <td class="pd-note" :data-label="t('monitoring.tokens.paid.col_note')">{{ it.note }}</td>
              <td class="pd-row-actions">
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
        </table>
      </div>
      <EffectivePriceTable v-if="effective" :view="effective" />
      <p v-else-if="effectiveFailed" class="pd-error" data-test="paid-effective-error">{{ t('monitoring.tokens.paid.effective_error') }}</p>
    </template>
  </section>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { fmtMoney } from '~/utils/monitoring-tokens.mjs'
import { emptyPaidForm, paidBody, paidCurrencies, paidEffectiveOf, paidFormOf, paidItemsOf, sortPaidItems } from '~/utils/monitoring-paid.mjs'
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
.pd-sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
</style>
