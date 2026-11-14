<!-- SPL-5433 step c (spec 123 16.4; owner poll 2ff12c21 answer 4 B): the
     employer side of one month, computed by the hub from the year's rates.
     One row per person (the code; the name only to a reader who holds it),
     each contribution computed, typed (a payslip's value wins, a difference
     is flagged) or booked. Book writes the computed amounts as lines, so the
     cost reports carry them; a closed month books nothing. The year's rates
     are listed, and set or removed by a costs.write reader. Loaded when
     opened (the HR tab's card, CostEntriesCard.vue); 'booked' reloads its
     list. -->
<template>
  <details class="hr-payroll" data-test="hr-payroll" @toggle="onToggle">
    <summary>
      {{ t('expenses.hr.payroll.title', { month }) }}
      <span v-if="payroll.flags" class="hr-flag" data-test="hr-payroll-flags">{{ t('expenses.hr.payroll.flags', { n: payroll.flags }) }}</span>
    </summary>
    <p v-if="state === 'loading'" class="muted" data-test="hr-payroll-loading">{{ t('expenses.hr.payroll.loading') }}</p>
    <p v-else-if="state === 'error'" class="hr-err" role="alert" data-test="hr-payroll-error">{{ refused }}</p>
    <template v-else-if="state === 'ok'">
      <p v-if="!payroll.people.length" class="muted" data-test="hr-payroll-empty">{{ t('expenses.hr.payroll.empty', { month }) }}</p>
      <div v-else class="hr-payroll-wrap">
        <table class="hr-payroll-table" data-test="hr-payroll-table">
          <thead>
            <tr>
              <th scope="col">{{ t('expenses.hr.payroll.col_person') }}</th>
              <th scope="col" class="num">{{ t('expenses.hr.payroll.col_gross') }}</th>
              <th scope="col">{{ t('expenses.hr.payroll.col_employer') }}</th>
              <th scope="col" class="num">{{ t('expenses.hr.payroll.col_other') }}</th>
              <th scope="col" class="num">{{ t('expenses.hr.payroll.col_cost') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in payroll.people" :key="r.personId + r.currency" data-test="hr-payroll-row" :data-flags="r.flags">
              <td :data-label="t('expenses.hr.payroll.col_person')">
                <strong>{{ r.code }}</strong>
                <span v-if="nameOf(r.personId)" class="muted"> {{ nameOf(r.personId) }}</span>
              </td>
              <td class="num" :data-label="t('expenses.hr.payroll.col_gross')">{{ fmtMoney(r.gross, r.currency, locale) }}</td>
              <td :data-label="t('expenses.hr.payroll.col_employer')">
                <strong data-test="hr-payroll-employer">{{ fmtMoney(r.employerTotal, r.currency, locale) }}</strong>
                <ul class="hr-payroll-lines">
                  <li v-for="l in r.employer" :key="l.component" :class="{ 'hr-flag': l.flag }" data-test="hr-payroll-line" :data-flag="l.flag">
                    {{ labelOf(l.component) }}<template v-if="l.ratePct !== null"> {{ fmtPct(l.ratePct) }}</template>:
                    {{ fmtMoney(l.amount, r.currency, locale) }}
                    <span class="muted">({{ t('expenses.hr.payroll.note_' + hrPayrollLineNote(l).key, { amount: fmtMoney(hrPayrollLineNote(l).amount, r.currency, locale) }) }})</span>
                  </li>
                </ul>
              </td>
              <td class="num" :data-label="t('expenses.hr.payroll.col_other')">{{ fmtMoney(r.other, r.currency, locale) }}</td>
              <td class="num" :data-label="t('expenses.hr.payroll.col_cost')" data-test="hr-payroll-cost">{{ fmtMoney(r.cost, r.currency, locale) }}</td>
            </tr>
          </tbody>
          <tfoot>
            <tr v-for="tot in payroll.totals" :key="tot.currency" data-test="hr-payroll-total">
              <th scope="row">{{ t('expenses.hr.payroll.total', { currency: tot.currency }) }}</th>
              <td class="num">{{ fmtMoney(tot.gross, tot.currency, locale) }}</td>
              <td>{{ fmtMoney(tot.employerTotal, tot.currency, locale) }}</td>
              <td class="num">{{ fmtMoney(tot.other, tot.currency, locale) }}</td>
              <td class="num">{{ fmtMoney(tot.cost, tot.currency, locale) }}</td>
            </tr>
          </tfoot>
        </table>
      </div>
      <div v-if="!readonly" class="hr-payroll-book">
        <p v-if="payroll.closed" class="muted" data-test="hr-payroll-closed">{{ t('expenses.hr.payroll.closed') }}</p>
        <button v-else-if="payroll.toBook" type="button" class="btn" :disabled="busy" data-test="hr-payroll-book" @click="book">
          {{ t('expenses.hr.payroll.book', { n: payroll.toBook }) }}
        </button>
        <span v-if="bookedMsg" class="muted" role="status" data-test="hr-payroll-booked">{{ bookedMsg }}</span>
      </div>

      <h4 class="hr-rates-title">{{ t('expenses.hr.payroll.rates', { year }) }}</h4>
      <p v-if="!rates.length" class="muted" data-test="hr-rates-none">{{ t('expenses.hr.payroll.rates_none', { year }) }}</p>
      <ul v-else class="hr-rates-list">
        <li v-for="rt in rates" :key="rt.component" data-test="hr-rate">
          <strong>{{ labelOf(rt.component) }}</strong> {{ fmtPct(rt.ratePct) }}
          <span class="muted">{{ [rt.appliesTo.map((x: string) => t('expenses.hr.type.' + x)).join(', '), rt.source].filter(Boolean).join(' · ') }}</span>
          <button v-if="!readonly" type="button" class="btn btn-link" :disabled="busy" data-test="hr-rate-delete" @click="removeRate(rt.component)">{{ t('expenses.hr.payroll.rate_delete') }}</button>
        </li>
      </ul>
      <form v-if="!readonly" class="hr-rate-form" data-test="hr-rate-form" novalidate @submit.prevent="saveRate">
        <select v-model="f.component" :aria-label="t('expenses.hr.component')" data-test="hr-rate-component">
          <option value="" disabled>{{ t('expenses.hr.component') }}</option>
          <option v-for="c in rateComponents" :key="c.component" :value="c.component">{{ c.label }}</option>
        </select>
        <input v-model="f.ratePct" type="text" inputmode="decimal" maxlength="9" :placeholder="t('expenses.hr.payroll.rate_pct')" :aria-label="t('expenses.hr.payroll.rate_pct')" data-test="hr-rate-pct">
        <fieldset class="hr-rate-types">
          <legend>{{ t('expenses.hr.payroll.rate_applies') }}</legend>
          <label v-for="ty in HR_EMPLOYMENT_TYPES" :key="ty"><input v-model="f.appliesTo" type="checkbox" :value="ty" :data-test="'hr-rate-type-' + ty"> {{ t('expenses.hr.type.' + ty) }}</label>
        </fieldset>
        <input v-model="f.source" type="text" maxlength="200" :placeholder="t('expenses.hr.payroll.rate_source')" :aria-label="t('expenses.hr.payroll.rate_source')" data-test="hr-rate-source">
        <button type="submit" class="btn" :disabled="busy" data-test="hr-rate-save">{{ t('expenses.hr.payroll.rate_save') }}</button>
        <span v-if="problem" class="hr-err" role="alert" data-test="hr-rate-error">{{ t('expenses.hr.payroll.' + problem) }}</span>
      </form>
      <p v-if="actionError" class="hr-err" role="alert" data-test="hr-payroll-refused">{{ actionError }}</p>
    </template>
  </details>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import {
  checkHrRateForm, emptyHrRateForm, HR_EMPLOYMENT_TYPES, hrPayrollLineNote, hrPayrollOf, hrRateBody, hrRateComponents, hrRatesOf,
} from '~/utils/hr-costs.mjs'

type Op = 'hr_rates' | 'hr_rate_set' | 'hr_rate_delete' | 'hr_payroll' | 'hr_payroll_book'
type PayrollApi = { fleetPaid: (op: Op, a?: unknown, b?: unknown) => Promise<unknown> }
type Person = { id: string, code: string, name: string }
type Component = { component: string, group: string, label: string }
const props = defineProps<{ month: string, people: Person[], components: Component[], readonly?: boolean }>()
const emit = defineEmits<{ (e: 'booked'): void }>()
const { t, locale } = useI18n({ useScope: 'global' })
const api = () => useSpoolApi() as unknown as PayrollApi

const state = ref<'idle' | 'loading' | 'ok' | 'error'>('idle')
const payroll = ref(hrPayrollOf(null))
const rates = ref<ReturnType<typeof hrRatesOf>['rates']>([])
const f = reactive(emptyHrRateForm())
const problem = ref('')
const refused = ref('')
const actionError = ref('')
const bookedMsg = ref('')
const busy = ref(false)
const year = computed(() => props.month.slice(0, 4))
const rateComponents = computed(() => hrRateComponents(props.components) as Component[])
const labelOf = (c: string) => props.components.find((x) => x.component === c)?.label || c
const nameOf = (id: string) => props.people.find((p) => p.id === id)?.name || ''
const fmtPct = (v: number) => new Intl.NumberFormat(locale.value, { maximumFractionDigits: 4 }).format(v) + ' %'

/* the hub's own words when it refuses: its detail, else its token */
const hubWhy = (e: unknown) => {
  const err = e as { detail?: string, token?: string, message?: string }
  return String((err && (err.detail || err.token || err.message)) || '')
}

async function load() {
  if (state.value === 'idle') state.value = 'loading'
  try {
    const [p, r] = await Promise.all([api().fleetPaid('hr_payroll', props.month), api().fleetPaid('hr_rates', year.value)])
    payroll.value = hrPayrollOf(p)
    rates.value = hrRatesOf(r).rates
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

function book() {
  bookedMsg.value = ''
  return act(async () => {
    const got = await api().fleetPaid('hr_payroll_book', props.month) as { booked?: number, removed?: number }
    bookedMsg.value = t('expenses.hr.payroll.booked', { n: Number(got?.booked) || 0, m: Number(got?.removed) || 0 })
    emit('booked')
  })
}

function saveRate() {
  problem.value = checkHrRateForm(f, props.components)
  if (problem.value) return
  return act(async () => {
    await api().fleetPaid('hr_rate_set', year.value, { component: f.component, ...hrRateBody(f) })
    Object.assign(f, emptyHrRateForm())
  })
}

function removeRate(component: string) {
  return act(() => api().fleetPaid('hr_rate_delete', year.value, component))
}

/* another month in the add form, or a line added or deleted: read again once opened */
watch(() => props.month, () => { if (state.value !== 'idle') load() })
defineExpose({ reload: () => (state.value !== 'idle' ? load() : undefined) })
</script>

<style scoped>
.hr-payroll { border: 1px solid var(--color-border); border-radius: var(--radius-md); padding: 6px 10px; }
.hr-payroll summary { cursor: pointer; font-weight: 600; }
.hr-payroll-wrap { overflow-x: auto; }
.hr-payroll-table { border-collapse: collapse; width: 100%; margin: 6px 0; }
.hr-payroll-table th, .hr-payroll-table td { padding: 4px 6px; text-align: left; vertical-align: top; border-bottom: 1px solid var(--color-border); }
.hr-payroll-table .num { text-align: right; white-space: nowrap; }
.hr-payroll-lines { list-style: none; margin: 2px 0 0; padding: 0; font-size: 0.9em; }
.hr-payroll-lines li { overflow-wrap: anywhere; }
.hr-flag { color: var(--color-danger); font-weight: 600; margin-left: 6px; }
.hr-payroll-lines .hr-flag { margin-left: 0; }
.hr-payroll-book { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 4px 0; }
.hr-rates-title { margin: 10px 0 4px; font-size: 1em; }
.hr-rates-list { list-style: none; margin: 0 0 6px; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.hr-rates-list li { display: flex; flex-wrap: wrap; gap: 4px 10px; align-items: center; overflow-wrap: anywhere; }
.hr-rate-form { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.hr-rate-form input[type=text], .hr-rate-form select { min-width: 0; max-width: 16rem; font: inherit; }
.hr-rate-types { border: 0; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 4px 10px; }
.hr-rate-types legend { float: left; margin-right: 6px; }
.hr-err { color: var(--color-danger); }
@media (max-width: 820px) {
  .hr-payroll-table thead { display: none; }
  .hr-payroll-table tr { display: block; border-bottom: 1px solid var(--color-border); padding: 4px 0; }
  .hr-payroll-table td, .hr-payroll-table th { display: flex; justify-content: space-between; gap: 8px; border: 0; text-align: left; }
  .hr-payroll-table td::before { content: attr(data-label); color: var(--color-text-muted, inherit); }
  .hr-payroll-table .num { text-align: right; }
}
</style>
