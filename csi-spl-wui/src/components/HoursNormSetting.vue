<!-- Tenant settings -> Hours, spec 107 FR-41 (SPL-5440, section 22.2): the
     workspace's average hours per day, a soft norm. A holder of hours.norm
     (biz_owner, product_owner, admin) reads and sets it through GET / PUT
     /v1/hours/norm; typed as h:mm (or 7.5), 0:00 or empty = no norm. Its own
     load and save; the card and its heading are pages/tenant-settings/hours.vue's. -->
<template>
  <form class="hn" data-test="tenant-hours-norm" @submit.prevent="save">
    <label class="hn-field">
      <span>{{ t('tenant_settings.hours_norm') }}</span>
      <input
        v-model="text"
        type="text"
        inputmode="decimal"
        autocomplete="off"
        :placeholder="t('tenant_settings.hours_norm_placeholder')"
        :disabled="loading || !!loadError"
        :aria-invalid="invalid ? 'true' : 'false'"
        data-test="tenant-hours-norm-input"
      >
      <small class="muted">{{ t('tenant_settings.hours_norm_hint') }}</small>
    </label>
    <p v-if="loadError" class="hn-error" role="alert">{{ loadError }}</p>
    <div class="hn-actions">
      <button type="submit" class="btn" :disabled="busy || loading || !!loadError || invalid || !dirty" data-test="tenant-hours-norm-save">{{ t('tenant_settings.save') }}</button>
      <p v-if="notice" class="hn-notice" role="status" data-test="tenant-hours-norm-notice">{{ notice }}</p>
      <p v-if="error || invalid" class="hn-error" role="alert" data-test="tenant-hours-norm-error">{{ invalid ? t('tenant_settings.hours_norm_invalid') : error }}</p>
    </div>
  </form>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { tenantSettingsErrorKey } from '~/utils/tenant-settings.mjs'
import { hoursHhmm } from '~/utils/hours-calendar.mjs'
import { hoursNormCall, hoursNormOf, hoursNormParse } from '~/utils/hours-norm.mjs'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()

const stored = ref(0)
const text = ref('')
const loading = ref(true)
const loadError = ref('')
const busy = ref(false)
const error = ref('')
const notice = ref('')

const parsed = computed(() => hoursNormParse(text.value))
const invalid = computed(() => Number.isNaN(parsed.value))
const dirty = computed(() => !invalid.value && parsed.value !== stored.value)

function take(body: unknown) {
  stored.value = hoursNormOf((body as { norm_day_minutes?: unknown } | null)?.norm_day_minutes)
  text.value = stored.value > 0 ? hoursHhmm(stored.value) : ''
}

async function load() {
  try {
    take(await hoursNormCall(api))
    loadError.value = ''
  } catch (e) {
    loadError.value = t(tenantSettingsErrorKey(e))
  } finally {
    loading.value = false
  }
}

async function save() {
  if (busy.value || !dirty.value) return
  busy.value = true
  error.value = ''
  notice.value = ''
  try {
    take(await hoursNormCall(api, parsed.value))
    notice.value = t('tenant_settings.saved')
  } catch (e) {
    error.value = t(tenantSettingsErrorKey(e))
  } finally {
    busy.value = false
  }
}

watch(text, () => { notice.value = '' })
watch(() => session.state, (st) => {
  if (st === 'in' || api.mock) void load()
}, { immediate: true })
</script>

<style scoped>
.hn { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.hn-field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.hn-field input {
  max-width: 10ch;
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.hn-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.hn-notice { margin: 0; color: var(--color-ok); }
.hn-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .hn-field input { max-width: none; min-height: var(--tap, 44px); }
  .hn-actions .btn { min-height: var(--tap, 44px); padding-block: 0; }
}
</style>
