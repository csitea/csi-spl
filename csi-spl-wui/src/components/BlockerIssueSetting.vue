<!-- "Blocker to issue after N minutes", inside Tenant settings -> General
     next to the issue key prefix: a registered tenants.settings key (spec
     098) saved through PATCH /v1/tenant/settings {settings: {...}}. A
     blocker that tags a person or an agent who does not answer in its topic
     within N minutes becomes an issue assigned to them; 0 turns it off
     (owner HUM-10, csitea e48433ef msg 2512ff1f). tenant.settings, like the
     page. Its own load and save, like MarketingSwitch. -->
<template>
  <div class="bi" data-test="tenant-blocker-issue">
    <h4 class="bi-title">{{ t('tenant_settings.blocker_issue_title') }}</h4>
    <p v-if="loading" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="loadError" class="bi-error" role="alert">{{ loadError }}</p>
    <form v-else class="bi-form" @submit.prevent="save">
      <label class="bi-field">
        <span>{{ t('tenant_settings.blocker_issue_minutes') }}</span>
        <input v-model.number="form" type="number" inputmode="numeric" :min="BLOCKER_MINUTES_RANGE.min" :max="BLOCKER_MINUTES_RANGE.max" step="1" data-test="tenant-blocker-issue-minutes">
        <small class="muted">{{ t('tenant_settings.blocker_issue_hint', BLOCKER_MINUTES_RANGE) }}</small>
      </label>
      <div class="bi-actions">
        <button type="submit" class="btn" :disabled="busy || !dirty" data-test="tenant-blocker-issue-save">{{ t('tenant_settings.save') }}</button>
        <p v-if="notice" class="bi-notice" role="status" data-test="tenant-blocker-issue-notice">{{ notice }}</p>
        <p v-if="error" class="bi-error" role="alert" data-test="tenant-blocker-issue-error">{{ error }}</p>
      </div>
    </form>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { tenantSettingsErrorKey } from '~/utils/tenant-settings.mjs'
import { BLOCKER_MINUTES_DEFAULT, BLOCKER_MINUTES_RANGE, blockerMinutesOf, blockerMinutesPatch } from '~/utils/blocker-settings.mjs'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()

const stored = ref(BLOCKER_MINUTES_DEFAULT)
const form = ref<number | string>(BLOCKER_MINUTES_DEFAULT)
const loading = ref(true)
const loadError = ref('')
const busy = ref(false)
const error = ref('')
const notice = ref('')

const dirty = computed(() => Object.keys(blockerMinutesPatch(stored.value, form.value)).length > 0)

function take(body: unknown) {
  stored.value = blockerMinutesOf((body as { settings?: unknown } | null)?.settings)
  form.value = stored.value
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
    take(await api.patchTenantSettings({ settings: blockerMinutesPatch(stored.value, form.value) }))
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
.bi { display: flex; flex-direction: column; gap: 8px; margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--color-border); min-width: 0; }
.bi-title { margin: 0 0 4px; font-size: 0.875rem; }
.bi-form { display: flex; flex-direction: column; gap: 14px; }
.bi-field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.bi-field input {
  max-width: 10ch;
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.bi-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.bi-notice { margin: 0; color: var(--color-ok); }
.bi-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .bi-field input { max-width: none; min-height: var(--tap, 44px); }
  .bi-actions .btn { min-height: var(--tap, 44px); padding-block: 0; }
}
</style>
