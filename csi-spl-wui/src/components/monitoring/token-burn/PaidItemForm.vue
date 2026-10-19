<!-- Spec 140 3.8 (SPL-2567): the form of one paid item, new or edited.
     It checks what the hub checks (utils/monitoring-paid.mjs checkPaidForm:
     the end after the start, an amount above 0, a known currency) and says
     the first problem before anything is sent; the hub's own refusal text,
     passed in as `refused`, shows under it as it came. -->
<template>
  <form class="pd-form" data-test="paid-form" novalidate @submit.prevent="submit">
    <h4>{{ t(editing ? 'monitoring.tokens.paid.form_edit_title' : 'monitoring.tokens.paid.form_add_title') }}</h4>
    <div class="pd-grid">
      <label>
        <span>{{ t('monitoring.tokens.col_vendor') }}</span>
        <select v-model="f.vendor" data-test="paid-f-vendor">
          <option v-for="v in TOKENS_VENDORS" :key="v" :value="v">{{ kindLabel(v) }}</option>
        </select>
      </label>
      <label>
        <span>{{ t('monitoring.tokens.paid.col_kind') }}</span>
        <select v-model="f.kind" data-test="paid-f-kind">
          <option v-for="k in PAID_KINDS" :key="k" :value="k">{{ t('monitoring.tokens.paid.kind_' + k) }}</option>
        </select>
      </label>
      <label class="pd-wide">
        <span>{{ t('monitoring.tokens.paid.col_plan') }}</span>
        <input v-model="f.planLabel" type="text" maxlength="100" data-test="paid-f-plan">
      </label>
      <label>
        <span>{{ t('monitoring.tokens.paid.col_quantity') }}</span>
        <input v-model.number="f.quantity" type="number" min="1" max="1000" step="1" data-test="paid-f-quantity">
      </label>
      <label>
        <span>{{ t('monitoring.tokens.paid.col_amount') }}</span>
        <input v-model="f.amount" type="number" min="0" step="0.01" inputmode="decimal" data-test="paid-f-amount">
      </label>
      <label>
        <span>{{ t('monitoring.tokens.paid.field_currency') }}</span>
        <select v-model="f.currency" data-test="paid-f-currency">
          <option v-for="c in currencyList" :key="c" :value="c">{{ c }}</option>
        </select>
      </label>
      <label>
        <span>{{ t('monitoring.tokens.paid.field_start') }}</span>
        <input v-model="f.periodStart" type="date" data-test="paid-f-start">
      </label>
      <label>
        <span>{{ t('monitoring.tokens.paid.field_end') }}</span>
        <input v-model="f.periodEnd" type="date" data-test="paid-f-end">
      </label>
      <label class="pd-wide">
        <span>{{ t('monitoring.tokens.paid.col_note') }}</span>
        <textarea v-model="f.note" rows="2" maxlength="2000" data-test="paid-f-note" />
      </label>
    </div>
    <p v-if="problem" class="pd-error" role="alert" data-test="paid-form-error">{{ t('monitoring.tokens.paid.' + problem) }}</p>
    <p v-else-if="refused" class="pd-error" role="alert" data-test="paid-form-refused">{{ t('monitoring.tokens.paid.refused', { why: refused }) }}</p>
    <div class="pd-actions">
      <button type="submit" class="btn primary" :disabled="busy" data-test="paid-save">{{ t('monitoring.tokens.paid.save') }}</button>
      <button type="button" class="btn" :disabled="busy" data-test="paid-cancel" @click="emit('cancel')">{{ t('monitoring.tokens.paid.cancel') }}</button>
    </div>
  </form>
</template>

<script setup lang="ts">
import { TOKENS_VENDORS } from '~/utils/monitoring-tokens.mjs'
import { checkPaidForm, emptyPaidForm, PAID_KINDS } from '~/utils/monitoring-paid.mjs'

type PaidForm = ReturnType<typeof emptyPaidForm>
const props = defineProps<{ initial: PaidForm, editing: boolean, currencies: string[], busy: boolean, refused: string }>()
const emit = defineEmits<{ save: [form: PaidForm], cancel: [] }>()
const { t, te } = useI18n({ useScope: 'global' })

const f = reactive<PaidForm>({ ...props.initial })
const problem = ref('')
/* an edited item keeps its currency in the list even if the hub no longer quotes it */
const currencyList = computed(() => (props.currencies.includes(f.currency) ? props.currencies : [...props.currencies, f.currency]))
const kindLabel = (v: string) => {
  const k = 'agents.kinds.' + (v === 'agy' ? 'antigravity' : v)
  return te(k) ? t(k) : v
}

function submit() {
  problem.value = checkPaidForm(f, props.currencies)
  if (!problem.value) emit('save', { ...f })
}
</script>

<style scoped>
.pd-form { display: flex; flex-direction: column; gap: 8px; padding: 10px 12px; border: 1px solid var(--color-border); border-radius: var(--radius-md); background: var(--color-surface); }
.pd-form h4 { margin: 0; font-size: 0.9375rem; }
.pd-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(11rem, 1fr)); gap: 8px 12px; }
.pd-grid label { display: flex; flex-direction: column; gap: 2px; min-width: 0; font-size: 0.875rem; }
.pd-grid label > span { color: var(--color-muted); font-size: 0.8125rem; }
.pd-grid input, .pd-grid select, .pd-grid textarea { min-width: 0; width: 100%; box-sizing: border-box; }
.pd-wide { grid-column: 1 / -1; }
.pd-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
.pd-actions { display: flex; flex-wrap: wrap; gap: 8px; }
</style>
