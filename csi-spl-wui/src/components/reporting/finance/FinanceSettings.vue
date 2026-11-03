<!-- Spec 125 row B7 (SPL-4741; owner answer Q2): the Netvisor owner's
     settings on Reporting -> Finance: the Netvisor company (test or prd),
     the bookkeeping account numbers the forecast reads (bank, VAT, tax; never
     a bank account number, C3) and the spec-123 vendors left out of the card
     costs (Q4). PUT /v1/netvisor/settings replaces all of them; the form
     checks what the hub checks before it sends. -->
<template>
  <form class="fin-card fin-settings" :aria-label="t('reporting.finance.settings.title')" data-test="finance-settings" @submit.prevent="save">
    <h3 class="fin-title">{{ t('reporting.finance.settings.title') }}</h3>
    <p class="muted fin-intro">{{ t('reporting.finance.settings.intro') }}</p>
    <label class="fin-field">
      <span>{{ t('reporting.finance.settings.env') }}</span>
      <select v-model="form.env" data-test="finance-settings-env">
        <option v-for="e in FINANCE_ENVS" :key="e" :value="e">{{ t('reporting.finance.env.' + e) }}</option>
      </select>
    </label>
    <label class="fin-field">
      <span>{{ t('reporting.finance.settings.bank') }}</span>
      <input v-model="form.bank" type="text" inputmode="numeric" autocomplete="off" :aria-invalid="bad === 'bank_account'" data-test="finance-settings-bank">
    </label>
    <label class="fin-field">
      <span>{{ t('reporting.finance.settings.vat') }}</span>
      <input v-model="form.vat" type="text" autocomplete="off" :aria-invalid="bad === 'vat_accounts'" data-test="finance-settings-vat">
    </label>
    <label class="fin-field">
      <span>{{ t('reporting.finance.settings.tax') }}</span>
      <input v-model="form.tax" type="text" autocomplete="off" :aria-invalid="bad === 'tax_accounts'" data-test="finance-settings-tax">
    </label>
    <p class="muted fin-hint">{{ t('reporting.finance.settings.accounts_hint') }}</p>
    <label class="fin-field">
      <span>{{ t('reporting.finance.settings.vendors') }}</span>
      <textarea v-model="form.vendors" rows="3" autocomplete="off" :aria-invalid="bad === 'vendor_exclusions'" data-test="finance-settings-vendors" />
    </label>
    <p class="muted fin-hint">{{ t('reporting.finance.settings.vendors_hint') }}</p>
    <div class="fin-actions">
      <button type="submit" class="btn" :disabled="busy" data-test="finance-settings-save">{{ t('reporting.finance.settings.save') }}</button>
      <span v-if="status === 'saved'" class="muted" role="status" data-test="finance-settings-saved">{{ t('reporting.finance.settings.saved') }}</span>
      <span v-else-if="status === 'invalid'" class="fin-error" role="alert" data-test="finance-settings-invalid" :data-field="bad">{{ t('reporting.finance.settings.invalid_' + bad) }}</span>
      <span v-else-if="status === 'error'" class="fin-error" role="alert" data-test="finance-settings-error">{{ t('reporting.finance.settings.error') }}</span>
    </div>
    <p v-if="updatedAt" class="muted fin-hint" data-test="finance-settings-updated">{{ t('reporting.finance.settings.updated', { time: isoDateTime(updatedAt) }) }}</p>
  </form>
</template>

<script setup lang="ts">
import { isoDateTime } from '~/utils/date-iso.mjs'
import { FINANCE_ENVS, NETVISOR_SETTINGS_PATH, netvisorCall, netvisorSettingsError, settingsBody, settingsForm } from '~/utils/reporting-finance.mjs'

type Settings = Record<string, unknown> & { updated_at?: string }
const props = defineProps<{ settings: Settings, api: { mock?: boolean, base?: string } }>()
const emit = defineEmits<{ saved: [settings: Settings] }>()

const { t } = useI18n({ useScope: 'global' })
const form = reactive(settingsForm(props.settings))
const busy = ref(false)
const status = ref<'' | 'saved' | 'invalid' | 'error'>('')
const bad = ref('')
const updatedAt = computed(() => String(props.settings?.updated_at || ''))

async function save() {
  const body = settingsBody(form)
  bad.value = netvisorSettingsError(body)
  if (bad.value) {
    status.value = 'invalid'
    return
  }
  busy.value = true
  status.value = ''
  try {
    const next = await netvisorCall(props.api, 'PUT', NETVISOR_SETTINGS_PATH, body) as Settings
    Object.assign(form, settingsForm(next))
    status.value = 'saved'
    emit('saved', next)
  } catch {
    status.value = 'error'
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
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
.fin-intro, .fin-hint { margin: 0; font-size: 0.875rem; }
.fin-field { display: flex; flex-direction: column; gap: 4px; max-width: 32rem; }
.fin-field input, .fin-field select, .fin-field textarea {
  width: 100%;
  box-sizing: border-box;
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
  font-size: 0.875rem;
}
.fin-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
.fin-error { color: var(--color-danger); }
@media (max-width: 820px) {
  .fin-field input, .fin-field select { min-height: var(--tap, 44px); }
  .fin-actions .btn { min-height: var(--tap, 44px); padding-block: 0; }
}
</style>
