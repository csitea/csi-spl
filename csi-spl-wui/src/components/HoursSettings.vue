<!-- Tenant settings -> General -> Hours (spec 107 section 4.2, T016): the
     workspace's four hours keys, registered tenants.settings keys (spec 098)
     saved through the same PATCH /v1/tenant/settings {settings: {...}}:
     the period, the days before a period freezes, the idle cutoff N and the
     zone the day and the freeze follow. tenant.settings, like the page. Its
     own load and save, like MarketingSwitch, so General's form is unchanged. -->
<template>
  <section class="hs" aria-labelledby="tenant-hours-h" data-test="tenant-hours">
    <h3 id="tenant-hours-h" class="hs-title">{{ t('tenant_settings.hours_title') }}</h3>
    <p class="muted hs-hint">{{ t('tenant_settings.hours_hint') }}</p>
    <p v-if="loading" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="loadError" class="hs-error" role="alert">{{ loadError }}</p>
    <form v-else class="hs-form" @submit.prevent="save">
      <label class="hs-field">
        <span>{{ t('tenant_settings.hours_period') }}</span>
        <select v-model="form.period" data-test="tenant-hours-period">
          <option v-for="p in HOURS_PERIOD_OPTIONS" :key="p" :value="p">{{ t(`tenant_settings.hours_period_${p}`) }}</option>
        </select>
      </label>
      <label class="hs-field">
        <span>{{ t('tenant_settings.hours_grace') }}</span>
        <input v-model.number="form.graceDays" type="number" inputmode="numeric" :min="HOURS_GRACE_RANGE.min" :max="HOURS_GRACE_RANGE.max" step="1" data-test="tenant-hours-grace">
        <small class="muted">{{ t('tenant_settings.hours_grace_hint', HOURS_GRACE_RANGE) }}</small>
      </label>
      <label class="hs-field">
        <span>{{ t('tenant_settings.hours_idle') }}</span>
        <input v-model.number="form.idleMinutes" type="number" inputmode="numeric" :min="HOURS_IDLE_RANGE.min" :max="HOURS_IDLE_RANGE.max" step="1" data-test="tenant-hours-idle">
        <small class="muted">{{ t('tenant_settings.hours_idle_hint', HOURS_IDLE_RANGE) }}</small>
      </label>
      <label class="hs-field">
        <span>{{ t('tenant_settings.hours_tz') }}</span>
        <select v-model="form.tz" data-test="tenant-hours-tz">
          <option v-for="z in zones" :key="z" :value="z">{{ z }}</option>
        </select>
        <small class="muted">{{ t('tenant_settings.hours_tz_hint') }}</small>
      </label>
      <div class="hs-actions">
        <button type="submit" class="btn" :disabled="busy || !dirty" data-test="tenant-hours-save">{{ t('tenant_settings.save') }}</button>
        <p v-if="notice" class="hs-notice" role="status" data-test="tenant-hours-notice">{{ notice }}</p>
        <p v-if="error" class="hs-error" role="alert" data-test="tenant-hours-error">{{ error }}</p>
      </div>
    </form>
  </section>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { tenantSettingsErrorKey } from '~/utils/tenant-settings.mjs'
import { knownTimeZones } from '~/utils/date-iso.mjs'
import { HOURS_DEFAULTS, HOURS_GRACE_RANGE, HOURS_IDLE_RANGE, HOURS_PERIOD_OPTIONS, hoursSettingsOf, hoursSettingsPatch } from '~/utils/hours-settings.mjs'
import type { HoursSettings, HoursSettingsForm } from '~/utils/hours-settings.mjs'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()

const stored = ref<HoursSettings>({ ...HOURS_DEFAULTS })
const form = reactive<HoursSettingsForm>({ ...HOURS_DEFAULTS })
const loading = ref(true)
const loadError = ref('')
const busy = ref(false)
const error = ref('')
const notice = ref('')

/* every zone this browser knows, plus the stored one if it does not */
const allZones: string[] = import.meta.client ? knownTimeZones() : []
const zones = computed(() => {
  const z = stored.value.tz
  return allZones.includes(z) ? allZones : [z, ...allZones]
})
const dirty = computed(() => Object.keys(hoursSettingsPatch(stored.value, form)).length > 0)

function take(body: unknown) {
  const s = hoursSettingsOf((body as { settings?: unknown } | null)?.settings)
  stored.value = s
  Object.assign(form, s)
}

async function load() {
  try {
    take(await api.getTenantSettings())
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
    take(await api.patchTenantSettings({ settings: hoursSettingsPatch(stored.value, form) }))
    notice.value = t('tenant_settings.saved')
  } catch (e) {
    error.value = t(tenantSettingsErrorKey(e))
  } finally {
    busy.value = false
  }
}

watch(() => session.state, (st) => {
  if (st === 'in' || api.mock) void load()
}, { immediate: true })
</script>

<style scoped>
.hs { margin-top: 24px; padding-top: 16px; border-top: 1px solid var(--color-border); min-width: 0; }
.hs-title { margin: 0 0 4px; font-size: 1rem; }
.hs-hint { margin: 0 0 12px; overflow-wrap: anywhere; }
.hs-form { display: flex; flex-direction: column; gap: 14px; }
.hs-field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.hs-field input, .hs-field select {
  max-width: 420px;
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.hs-field input { max-width: 10ch; }
.hs-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.hs-notice { margin: 0; color: var(--color-ok); }
.hs-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .hs-field input, .hs-field select { max-width: none; min-height: var(--tap, 44px); }
  /* no block padding: the tap height decides, 44..48 px at every font level */
  .hs-actions .btn { min-height: var(--tap, 44px); padding-block: 0; }
}
</style>
