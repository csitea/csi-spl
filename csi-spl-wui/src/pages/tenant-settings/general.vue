<!-- Tenant settings -> General (specs/046 §4.5): the tenant's display name
     (the tenant switcher and the tab title, SPL-959), its default locale
     (the invite mail's language when the admin's own is not sent) and the
     issue key prefix (W16, spec 047). tenant.settings. -->
<template>
  <SettingsSection id="tenant-general" :title="t('tenant_settings.general_title')" data-test="tenant-settings-general">
    <p v-if="loading" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="loadError" class="ts-error" role="alert">{{ loadError }}</p>
    <form v-else class="ts-form" @submit.prevent="save">
      <label class="ts-field">
        <span>{{ t('tenant_settings.display_name') }}</span>
        <input
          v-model="name"
          type="text"
          maxlength="200"
          autocomplete="off"
          :placeholder="tenantId"
          data-test="tenant-general-name"
        >
        <small class="muted">{{ t('tenant_settings.display_name_hint', { id: tenantId }) }}</small>
      </label>
      <div class="ts-field">
        <span id="tenant-general-locale-label">{{ t('tenant_settings.default_locale') }}</span>
        <div class="ts-locale">
          <LocaleCombobox v-model="locale" test-prefix="tenant-general-locale" labelled-by="tenant-general-locale-label" />
          <button v-if="locale" type="button" class="btn ghost" data-test="tenant-general-locale-clear" @click="locale = ''">
            {{ t('tenant_settings.locale_clear') }}
          </button>
        </div>
        <small class="muted">{{ locale ? t('tenant_settings.default_locale_hint') : t('tenant_settings.default_locale_unset') }}</small>
      </div>
      <label v-if="stored?.issuePrefix" class="ts-field">
        <span>{{ t('tenant_settings.issue_prefix') }}</span>
        <input
          v-model="prefix"
          type="text"
          maxlength="10"
          autocomplete="off"
          spellcheck="false"
          class="ts-prefix"
          data-test="tenant-general-issue-prefix"
        >
        <small class="muted">{{ t('tenant_settings.issue_prefix_hint', { prefix: issuePrefixOf(prefix) || stored.issuePrefix }) }}</small>
      </label>
      <div class="ts-actions">
        <button type="submit" class="btn" :disabled="busy || !dirty" data-test="tenant-general-save">{{ t('tenant_settings.save') }}</button>
        <p v-if="notice" class="ts-notice" role="status" data-test="tenant-general-notice">{{ notice }}</p>
        <p v-if="error" class="ts-error" role="alert" data-test="tenant-general-error">{{ error }}</p>
      </div>
    </form>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import LocaleCombobox from '~/components/LocaleCombobox.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { issuePrefixOf, normalizeTenantSettings, tenantSettingsErrorKey } from '~/utils/tenant-settings.mjs'
import type { TenantSettings } from '~/utils/tenant-settings.mjs'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()

const stored = ref<TenantSettings | null>(null)
const tenantId = computed(() => stored.value?.tenantId || '')
const name = ref('')
const locale = ref('')
const prefix = ref('')
const loading = ref(true)
const loadError = ref('')
const busy = ref(false)
const error = ref('')
const notice = ref('')

const prefixChanged = computed(() => Boolean(stored.value?.issuePrefix) && prefix.value.trim().toUpperCase() !== stored.value!.issuePrefix)
const dirty = computed(() => Boolean(stored.value) && (name.value.trim() !== stored.value!.displayName || locale.value !== stored.value!.defaultLocale || prefixChanged.value))

function take(s: TenantSettings) {
  stored.value = s
  name.value = s.displayName
  locale.value = s.defaultLocale
  prefix.value = s.issuePrefix
}

async function load() {
  try {
    take(normalizeTenantSettings(await api.getTenantSettings()))
    loadError.value = ''
  } catch (e) {
    loadError.value = t(tenantSettingsErrorKey(e))
  } finally {
    loading.value = false
  }
}

async function save() {
  const s = stored.value
  if (!s || busy.value) return
  const patch: { display_name?: string, default_locale?: string, issue_prefix?: string } = {}
  if (name.value.trim() !== s.displayName) patch.display_name = name.value.trim()
  if (locale.value !== s.defaultLocale) patch.default_locale = locale.value
  if (prefixChanged.value) {
    const p = issuePrefixOf(prefix.value)
    if (!p) { error.value = t('tenant_settings.error.bad_prefix'); return }
    patch.issue_prefix = p
  }
  busy.value = true
  error.value = ''
  notice.value = ''
  try {
    take(normalizeTenantSettings(await api.patchTenantSettings(patch)))
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
.ts-form { display: flex; flex-direction: column; gap: 14px; }
.ts-field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.ts-field input {
  max-width: 420px;
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.ts-prefix { max-width: 12ch; text-transform: uppercase; font-family: var(--font-mono, monospace); }
.ts-locale { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.ts-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.ts-notice { margin: 0; color: var(--color-ok); }
.ts-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .ts-field input { max-width: none; min-height: var(--tap, 44px); }
  .ts-actions .btn, .ts-locale .btn { min-height: var(--tap, 44px); }
}
</style>
