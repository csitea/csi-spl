<!-- SPL-5433 step d (spec 123 16.5; owner poll 2ff12c21 answer 4 B): the
     worker side of one month, computed by the hub, and the payslip check.
     One row per person and currency: gross, the year-to-date income, the
     employee's shares by age band, the tax from the year's card, the net,
     each against the payslip (a typed value wins, a difference is flagged).
     The worker side is part of the gross: never booked, never in a total.
     A costs.write reader's only (tax cards and payslips are personal), so
     CostEntriesCard.vue mounts it for a writer only. Loaded when opened. -->
<template>
  <details class="hr-worker" data-test="hr-worker" @toggle="onToggle">
    <summary>
      {{ t('expenses.hr.worker.title', { month }) }}
      <span v-if="flags" class="hr-flag" data-test="hr-worker-flags">{{ t('expenses.hr.payroll.flags', { n: flags }) }}</span>
    </summary>
    <p class="muted">{{ t('expenses.hr.worker.intro') }}</p>
    <p v-if="state === 'loading'" class="muted" data-test="hr-worker-loading">{{ t('expenses.hr.payroll.loading') }}</p>
    <p v-else-if="state === 'error'" class="hr-err" role="alert" data-test="hr-worker-error">{{ refused }}</p>
    <template v-else-if="state === 'ok'">
      <p v-if="!rows.length" class="muted" data-test="hr-worker-empty">{{ t('expenses.hr.payroll.empty', { month }) }}</p>
      <div v-else class="hr-worker-wrap">
        <table class="hr-worker-table" data-test="hr-worker-table">
          <thead>
            <tr>
              <th scope="col">{{ t('expenses.hr.payroll.col_person') }}</th>
              <th scope="col" class="num">{{ t('expenses.hr.payroll.col_gross') }}</th>
              <th scope="col" class="num">{{ t('expenses.hr.worker.col_ytd') }}</th>
              <th scope="col">{{ t('expenses.hr.worker.col_shares') }}</th>
              <th scope="col">{{ t('expenses.hr.worker.col_tax') }}</th>
              <th scope="col" class="num">{{ t('expenses.hr.worker.col_net') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="w in rows" :key="w.personId + w.currency" data-test="hr-worker-row" :data-flags="w.flags">
              <td :data-label="t('expenses.hr.payroll.col_person')">
                <strong>{{ w.code }}</strong>
                <span v-if="nameOf(w.personId)" class="muted"> {{ nameOf(w.personId) }}</span>
                <span v-for="m in w.missing" :key="m" class="hr-flag" data-test="hr-worker-missing" :data-missing="m">{{ t('expenses.hr.worker.missing_' + m) }}</span>
              </td>
              <td class="num" :data-label="t('expenses.hr.payroll.col_gross')">{{ fmtMoney(w.gross, w.currency, locale) }}</td>
              <td class="num" :data-label="t('expenses.hr.worker.col_ytd')" data-test="hr-worker-ytd">
                {{ fmtMoney(w.ytd, w.currency, locale) }}
                <span class="muted">{{ t('expenses.hr.worker.ytd_before', { amount: fmtMoney(w.ytdBefore, w.currency, locale) }) }}</span>
              </td>
              <td :data-label="t('expenses.hr.worker.col_shares')">
                <ul class="hr-worker-lines">
                  <li v-for="l in w.shares" :key="l.kind" :class="{ 'hr-flag': l.flag }" data-test="hr-worker-share" :data-flag="l.flag">
                    {{ t('expenses.hr.worker.kind_' + l.kind) }}<template v-if="l.ratePct !== null"> {{ fmtPct(l.ratePct) }}</template>:
                    {{ fmtMoney(l.amount, w.currency, locale) }}
                    <span class="muted">({{ note(l, w.currency) }})</span>
                  </li>
                </ul>
              </td>
              <td :data-label="t('expenses.hr.worker.col_tax')" :class="{ 'hr-flag': w.tax.flag }" data-test="hr-worker-tax" :data-flag="w.tax.flag">
                {{ fmtMoney(w.tax.amount, w.currency, locale) }}
                <span class="muted">({{ note(w.tax, w.currency) }})</span>
                <span v-if="w.taxCard" class="muted hr-worker-card">{{ t('expenses.hr.worker.card_short', { base: fmtPct(w.taxCard.basePct), extra: fmtPct(w.taxCard.extraPct), limit: fmtMoney(w.taxCard.incomeLimit, w.currency, locale) }) }}</span>
              </td>
              <td class="num" :data-label="t('expenses.hr.worker.col_net')" :class="{ 'hr-flag': w.net.flag }" data-test="hr-worker-net" :data-flag="w.net.flag">
                {{ fmtMoney(w.net.amount, w.currency, locale) }}
                <span class="muted">({{ note(w.net, w.currency) }})</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <h4 class="hr-worker-sub">{{ t('expenses.hr.worker.slip_title', { month }) }}</h4>
      <form class="hr-worker-form" data-test="hr-slip-form" novalidate @submit.prevent="saveSlip">
        <select v-model="slip.personId" :aria-label="t('expenses.hr.person')" data-test="hr-slip-person">
          <option value="" disabled>{{ t('expenses.hr.person') }}</option>
          <option v-for="p in people" :key="p.id" :value="p.id">{{ p.code }}</option>
        </select>
        <input v-model="slip.currency" type="text" maxlength="3" :aria-label="t('expenses.hr.worker.currency')" class="hr-worker-cur" data-test="hr-slip-currency">
        <input v-for="k in HR_PAYSLIP_FIELDS" :key="k" v-model="slip[k]" type="text" inputmode="decimal" maxlength="14"
               :placeholder="t('expenses.hr.worker.slip_' + k)" :aria-label="t('expenses.hr.worker.slip_' + k)" :data-test="'hr-slip-' + k">
        <button type="submit" class="btn" :disabled="busy || closed" data-test="hr-slip-save">{{ t('expenses.hr.worker.slip_save') }}</button>
        <button type="button" class="btn btn-link" :disabled="busy || closed || !slip.personId" data-test="hr-slip-delete" @click="removeSlip">{{ t('expenses.hr.worker.slip_delete') }}</button>
        <span v-if="closed" class="muted" data-test="hr-slip-closed">{{ t('expenses.hr.worker.slip_closed') }}</span>
        <span v-if="slipProblem" class="hr-err" role="alert" data-test="hr-slip-error">{{ t('expenses.hr.worker.' + slipProblem) }}</span>
      </form>

      <h4 class="hr-worker-sub">{{ t('expenses.hr.worker.cards_title', { year }) }}</h4>
      <ul v-if="cards.length" class="hr-worker-list">
        <li v-for="c in cards" :key="c.personId" data-test="hr-card">
          <strong>{{ codeOf(c.personId) }}</strong>
          {{ t('expenses.hr.worker.card_short', { base: fmtPct(c.basePct), extra: fmtPct(c.extraPct), limit: fmtMoney(c.incomeLimit, 'EUR', locale) }) }}
          <span v-if="c.source" class="muted">· {{ c.source }}</span>
          <button type="button" class="btn btn-link" :disabled="busy" data-test="hr-card-delete" @click="removeCard(c.personId)">{{ t('expenses.hr.payroll.rate_delete') }}</button>
        </li>
      </ul>
      <p v-else class="muted" data-test="hr-cards-none">{{ t('expenses.hr.worker.cards_none', { year }) }}</p>
      <form class="hr-worker-form" data-test="hr-card-form" novalidate @submit.prevent="saveCard">
        <select v-model="card.personId" :aria-label="t('expenses.hr.person')" data-test="hr-card-person">
          <option value="" disabled>{{ t('expenses.hr.person') }}</option>
          <option v-for="p in people" :key="p.id" :value="p.id">{{ p.code }}</option>
        </select>
        <input v-model="card.basePct" type="text" inputmode="decimal" maxlength="6" :placeholder="t('expenses.hr.worker.card_base')" :aria-label="t('expenses.hr.worker.card_base')" data-test="hr-card-base">
        <input v-model="card.extraPct" type="text" inputmode="decimal" maxlength="6" :placeholder="t('expenses.hr.worker.card_extra')" :aria-label="t('expenses.hr.worker.card_extra')" data-test="hr-card-extra">
        <input v-model="card.incomeLimit" type="text" inputmode="decimal" maxlength="14" :placeholder="t('expenses.hr.worker.card_limit')" :aria-label="t('expenses.hr.worker.card_limit')" data-test="hr-card-limit">
        <input v-model="card.source" type="text" maxlength="200" :placeholder="t('expenses.hr.payroll.rate_source')" :aria-label="t('expenses.hr.payroll.rate_source')" data-test="hr-card-source">
        <button type="submit" class="btn" :disabled="busy" data-test="hr-card-save">{{ t('expenses.hr.worker.card_save') }}</button>
        <span v-if="cardProblem" class="hr-err" role="alert" data-test="hr-card-error">{{ t('expenses.hr.worker.' + cardProblem) }}</span>
      </form>

      <h4 class="hr-worker-sub">{{ t('expenses.hr.worker.bands_title', { year }) }}</h4>
      <ul v-if="bands.length" class="hr-worker-list">
        <li v-for="b in bands" :key="b.kind + b.ageFrom" data-test="hr-band">
          <strong>{{ t('expenses.hr.worker.kind_' + b.kind) }}</strong>
          {{ t('expenses.hr.worker.band_ages', { from: b.ageFrom, to: b.ageTo }) }} {{ fmtPct(b.ratePct) }}
          <span v-if="b.source" class="muted">· {{ b.source }}</span>
          <button type="button" class="btn btn-link" :disabled="busy" data-test="hr-band-delete" @click="removeBand(b.kind, b.ageFrom)">{{ t('expenses.hr.payroll.rate_delete') }}</button>
        </li>
      </ul>
      <p v-else class="muted" data-test="hr-bands-none">{{ t('expenses.hr.worker.bands_none', { year }) }}</p>
      <form class="hr-worker-form" data-test="hr-band-form" novalidate @submit.prevent="saveBand">
        <select v-model="band.kind" :aria-label="t('expenses.hr.worker.band_kind')" data-test="hr-band-kind">
          <option v-for="k in HR_WORKER_KINDS" :key="k" :value="k">{{ t('expenses.hr.worker.kind_' + k) }}</option>
        </select>
        <input v-model="band.ageFrom" type="text" inputmode="numeric" maxlength="3" :placeholder="t('expenses.hr.worker.band_from')" :aria-label="t('expenses.hr.worker.band_from')" data-test="hr-band-from">
        <input v-model="band.ageTo" type="text" inputmode="numeric" maxlength="3" :placeholder="t('expenses.hr.worker.band_to')" :aria-label="t('expenses.hr.worker.band_to')" data-test="hr-band-to">
        <input v-model="band.ratePct" type="text" inputmode="decimal" maxlength="9" :placeholder="t('expenses.hr.payroll.rate_pct')" :aria-label="t('expenses.hr.payroll.rate_pct')" data-test="hr-band-pct">
        <input v-model="band.source" type="text" maxlength="200" :placeholder="t('expenses.hr.payroll.rate_source')" :aria-label="t('expenses.hr.payroll.rate_source')" data-test="hr-band-source">
        <button type="submit" class="btn" :disabled="busy" data-test="hr-band-save">{{ t('expenses.hr.worker.band_save') }}</button>
        <span v-if="bandProblem" class="hr-err" role="alert" data-test="hr-band-error">{{ t('expenses.hr.worker.' + bandProblem) }}</span>
      </form>
      <p v-if="actionError" class="hr-err" role="alert" data-test="hr-worker-refused">{{ actionError }}</p>
    </template>
  </details>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import {
  checkHrPayslipForm, checkHrTaxCardForm, emptyHrBandForm, emptyHrPayslipForm, emptyHrTaxCardForm, HR_PAYSLIP_FIELDS, HR_WORKER_KINDS,
  hrBandsWith, hrPayrollOf, hrPayslipBody, hrTaxCardBody, hrTaxCardsOf, hrWorkerLineNote, hrWorkerOf, hrWorkerRatesOf,
} from '~/utils/hr-costs.mjs'

type Op = 'hr_payroll' | 'hr_worker_rates' | 'hr_worker_rates_set' | 'hr_tax_cards' | 'hr_tax_card_set' | 'hr_tax_card_delete' | 'hr_payslip_set' | 'hr_payslip_delete'
type WorkerApi = { fleetPaid: (op: Op, a?: unknown, b?: unknown) => Promise<unknown> }
type Person = { id: string, code: string, name: string }
type Line = { kind: string, ratePct: number | null, computed: number, typed: number | null, amount: number, diff: number, flag: string }
type Row = { personId: string, code: string, currency: string, age: number, gross: number, ytdBefore: number, ytd: number,
  taxCard: { basePct: number, extraPct: number, incomeLimit: number } | null, shares: Line[], tax: Line, net: Line, missing: string[], flags: number }
type Band = { kind: string, ageFrom: number, ageTo: number, ratePct: number, source: string }
type Card = { personId: string, basePct: number, extraPct: number, incomeLimit: number, source: string }
const props = defineProps<{ month: string, people: Person[] }>()
const { t, locale } = useI18n({ useScope: 'global' })
const api = () => useSpoolApi() as unknown as WorkerApi

const state = ref<'idle' | 'loading' | 'ok' | 'error'>('idle')
const rows = ref<Row[]>([])
const bands = ref<Band[]>([])
const cards = ref<Card[]>([])
const closed = ref(false)
const slip = reactive<Record<string, string>>(emptyHrPayslipForm())
const card = reactive(emptyHrTaxCardForm())
const band = reactive(emptyHrBandForm())
const slipProblem = ref('')
const cardProblem = ref('')
const bandProblem = ref('')
const refused = ref('')
const actionError = ref('')
const busy = ref(false)
const year = computed(() => props.month.slice(0, 4))
const flags = computed(() => rows.value.reduce((n: number, w: Row) => n + w.flags, 0))
const nameOf = (id: string) => props.people.find((p) => p.id === id)?.name || ''
const codeOf = (id: string) => props.people.find((p) => p.id === id)?.code || id
const fmtPct = (v: number) => new Intl.NumberFormat(locale.value, { maximumFractionDigits: 4 }).format(v) + ' %'
const note = (l: Line, currency: string) => {
  const n = hrWorkerLineNote(l)
  return t('expenses.hr.payroll.note_' + n.key, { amount: fmtMoney(n.amount, currency, locale.value) })
}

/* the hub's own words when it refuses: its detail, else its token */
const hubWhy = (e: unknown) => {
  const err = e as { detail?: string, token?: string, message?: string }
  return String((err && (err.detail || err.token || err.message)) || '')
}

async function load() {
  if (state.value === 'idle') state.value = 'loading'
  try {
    const [p, r, c] = await Promise.all([api().fleetPaid('hr_payroll', props.month), api().fleetPaid('hr_worker_rates', year.value), api().fleetPaid('hr_tax_cards', year.value)])
    rows.value = hrWorkerOf(p) as Row[]
    closed.value = hrPayrollOf(p).closed
    bands.value = hrWorkerRatesOf(r) as Band[]
    cards.value = hrTaxCardsOf(c) as Card[]
    state.value = 'ok'
  } catch (e) {
    refused.value = hubWhy(e)
    state.value = 'error'
  }
}

function onToggle(ev: Event) {
  if ((ev.target as HTMLDetailsElement).open && state.value === 'idle') load()
}

async function act(fn: () => Promise<unknown>) {
  actionError.value = ''
  busy.value = true
  try {
    await fn()
    await load()
  } catch (e) {
    actionError.value = hubWhy(e)
  } finally {
    busy.value = false
  }
}

function saveSlip() {
  slipProblem.value = checkHrPayslipForm(slip)
  if (slipProblem.value) return
  return act(async () => {
    await api().fleetPaid('hr_payslip_set', props.month, { person_id: slip.personId, ...hrPayslipBody(slip) })
    Object.assign(slip, emptyHrPayslipForm())
  })
}

function removeSlip() {
  return act(() => api().fleetPaid('hr_payslip_delete', props.month, { person_id: slip.personId, currency: slip.currency }))
}

function saveCard() {
  cardProblem.value = checkHrTaxCardForm(card)
  if (cardProblem.value) return
  return act(async () => {
    await api().fleetPaid('hr_tax_card_set', year.value, { person_id: card.personId, ...hrTaxCardBody(card) })
    Object.assign(card, emptyHrTaxCardForm())
  })
}

function removeCard(personId: string) {
  return act(() => api().fleetPaid('hr_tax_card_delete', year.value, personId))
}

function saveBand() {
  const got = hrBandsWith(band, bands.value) as { problem: string, bands?: unknown[] }
  bandProblem.value = got.problem
  if (got.problem) return
  return act(async () => {
    await api().fleetPaid('hr_worker_rates_set', year.value, { kind: band.kind, bands: got.bands, source: band.source.trim() })
    Object.assign(band, emptyHrBandForm())
  })
}

function removeBand(kind: string, ageFrom: number) {
  const left = bands.value.filter((b: Band) => b.kind === kind && b.ageFrom !== ageFrom)
    .map((b: Band) => ({ age_from: b.ageFrom, age_to: b.ageTo, rate_pct: b.ratePct }))
  const source = bands.value.find((b: Band) => b.kind === kind)?.source || ''
  return act(() => api().fleetPaid('hr_worker_rates_set', year.value, { kind, bands: left, source }))
}

/* another month in the add form, or a line added or deleted: read again once opened */
watch(() => props.month, () => { if (state.value !== 'idle') load() })
defineExpose({ reload: () => (state.value !== 'idle' ? load() : undefined) })
</script>

<style scoped>
.hr-worker { border: 1px solid var(--color-border); border-radius: var(--radius-md); padding: 6px 10px; }
.hr-worker summary { cursor: pointer; font-weight: 600; }
.hr-worker-wrap { overflow-x: auto; }
.hr-worker-table { border-collapse: collapse; width: 100%; margin: 6px 0; }
.hr-worker-table th, .hr-worker-table td { padding: 4px 6px; text-align: left; vertical-align: top; border-bottom: 1px solid var(--color-border); }
.hr-worker-table .num { text-align: right; white-space: nowrap; }
.hr-worker-table .num .muted, .hr-worker-card { display: block; font-size: 0.85em; }
.hr-worker-lines { list-style: none; margin: 0; padding: 0; font-size: 0.9em; }
.hr-worker-lines li { overflow-wrap: anywhere; }
.hr-flag { color: var(--color-danger); font-weight: 600; margin-left: 6px; }
.hr-worker-lines .hr-flag { margin-left: 0; }
.hr-worker-sub { margin: 10px 0 4px; font-size: 1em; }
.hr-worker-list { list-style: none; margin: 0 0 6px; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.hr-worker-list li { display: flex; flex-wrap: wrap; gap: 4px 10px; align-items: center; overflow-wrap: anywhere; }
.hr-worker-form { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.hr-worker-form input[type=text], .hr-worker-form select { min-width: 0; max-width: 12rem; font: inherit; }
.hr-worker-form .hr-worker-cur { max-width: 4rem; }
.hr-err { color: var(--color-danger); }
@media (max-width: 820px) {
  .hr-worker-table thead { display: none; }
  .hr-worker-table tr { display: block; border-bottom: 1px solid var(--color-border); padding: 4px 0; }
  .hr-worker-table td { display: flex; justify-content: space-between; gap: 8px; border: 0; text-align: left; flex-wrap: wrap; }
  .hr-worker-table td::before { content: attr(data-label); color: var(--color-text-muted, inherit); }
}
</style>
