<!-- Tenant settings -> Agent keys (spec 127 v1.4 section 8, row W1; spec 159
     v0.2 section 10, row T7; SPL-3745): the workspace's own API key per
     agent kind, for its biz owners and admins (vendor_keys.manage, spec 159
     3). Per kind: set, not set, exhausted (with retry, 159 9) or not
     available (grok and mistral wait for the vendor's terms, 159 4.2; agy
     for its check, 127 R5.2). An unconfirmed (operator-made) manager reads
     the rows and changes nothing (127 5.1). The typed key lives in one
     password field, goes out once and is cleared (127 L12); no route ever
     answers it back. The hub re-checks every call. -->
<template>
  <SettingsSection id="tenant-agent-keys" :title="t('tenant_settings.agent_keys.title')" data-test="tenant-settings-agent-keys">
    <p v-if="forbidden" class="muted" role="alert" data-test="vk-forbidden">{{ t('tenant_settings.agent_keys.forbidden') }}</p>
    <p v-else-if="loading" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="loadError" class="vk-error" role="alert">{{ loadError }}</p>
    <div v-else class="vk">
      <p class="muted vk-hint">{{ t('tenant_settings.agent_keys.hint') }}</p>
      <p v-if="!confirmed" class="vk-unconfirmed" role="status" data-test="vk-unconfirmed">{{ t('tenant_settings.agent_keys.unconfirmed') }}</p>
      <ul class="vk-rows">
        <li v-for="row in rows" :key="row.kind" class="vk-row" data-test="vk-row" :data-kind="row.kind" :data-state="stateOf(row)">
          <div class="vk-head">
            <strong class="vk-kind">{{ t('tenant_settings.agent_keys.kind.' + row.kind) }}</strong>
            <span class="vk-state" data-test="vk-state">{{ t('tenant_settings.agent_keys.state.' + stateOf(row)) }}</span>
          </div>
          <p v-if="stateOf(row) === 'not_available'" class="muted vk-line" data-test="vk-unavailable">
            {{ t(row.kind === 'agy' ? 'tenant_settings.agent_keys.not_supported' : 'tenant_settings.agent_keys.waiting_terms') }}
          </p>
          <template v-else>
            <p v-if="row.set" class="muted vk-line" data-test="vk-last4">
              {{ t('tenant_settings.agent_keys.set_line', { last4: row.last4, by: row.setBy, at: when(row.setAt) }) }}
            </p>
            <p v-if="stateOf(row) === 'exhausted'" class="vk-error vk-line" data-test="vk-exhausted">{{ t('tenant_settings.agent_keys.exhausted') }}</p>
            <VendorKeyControls v-if="confirmed" :row="row" :busy="busy === row.kind" @save="save" @remove="remove" @retry="retry" />
          </template>
          <p v-if="errors[row.kind]" class="vk-error vk-line" role="alert" data-test="vk-error">{{ errors[row.kind] }}</p>
          <p v-if="notices[row.kind]" class="vk-notice vk-line" role="status" data-test="vk-notice">{{ notices[row.kind] }}</p>
        </li>
      </ul>
    </div>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import VendorKeyControls from '~/components/VendorKeyControls.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { useAccessStore } from '~/stores/access'
import { normalizeVendorKeys, vendorKeyState, vendorKeysErrorKey, VENDOR_KEYS_PERM } from '~/utils/vendor-keys.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'

type VendorKeyRow = ReturnType<typeof normalizeVendorKeys>['rows'][number]

type VendorKeysApi = { vendorKeys: (op: 'list' | 'put' | 'delete' | 'retry', kind?: string, body?: unknown) => Promise<unknown> }

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi() as unknown as VendorKeysApi & { mock?: boolean }
const session = useSessionStore()
const access = useAccessStore()

const rows = ref<VendorKeyRow[]>([])
const confirmed = ref(true)
const loading = ref(true)
const loadError = ref('')
const busy = ref('')
const errors = reactive<Record<string, string>>({})
const notices = reactive<Record<string, string>>({})
const accessReady = ref(false)
const forbidden = computed(() => accessReady.value && !access.can(VENDOR_KEYS_PERM))

const stateOf = (row: VendorKeyRow) => vendorKeyState(row)

function when(iso: string): string {
  return isoDateTime(iso) || iso
}

function take(body: unknown) {
  const v = normalizeVendorKeys(body)
  rows.value = v.rows
  confirmed.value = v.confirmed
}

async function load() {
  try {
    take(await api.vendorKeys('list'))
    loadError.value = ''
  } catch (e) {
    loadError.value = t(vendorKeysErrorKey(e))
  } finally {
    loading.value = false
  }
}

/* one write on one kind: busy, then the reloaded rows, or the reason */
async function write(kind: string, call: () => Promise<unknown>, noticeKey: string): Promise<boolean> {
  busy.value = kind
  errors[kind] = ''
  notices[kind] = ''
  try {
    await call()
    take(await api.vendorKeys('list'))
    notices[kind] = t(noticeKey)
    return true
  } catch (e) {
    errors[kind] = t(vendorKeysErrorKey(e))
    return false
  } finally {
    busy.value = ''
  }
}

function save(kind: string, body: { key: string, base_url?: string } | null, error: string) {
  if (!body) {
    errors[kind] = t(error)
    return
  }
  void write(kind, () => api.vendorKeys('put', kind, body), 'tenant_settings.agent_keys.saved')
}

function remove(kind: string) {
  void write(kind, () => api.vendorKeys('delete', kind), 'tenant_settings.agent_keys.removed')
}

function retry(kind: string) {
  void write(kind, () => api.vendorKeys('retry', kind), 'tenant_settings.agent_keys.retried')
}

watch(() => session.state, (st) => {
  if (st !== 'in' && !api.mock) return
  void access.load().finally(() => { accessReady.value = true })
  void load()
}, { immediate: true })
</script>

<style scoped>
.vk { display: flex; flex-direction: column; gap: 12px; }
.vk-hint, .vk-line { margin: 0; }
.vk-unconfirmed { margin: 0; padding: 8px 10px; border: 1px solid var(--color-border-strong); }
.vk-rows { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 10px; }
.vk-row { display: flex; flex-direction: column; gap: 6px; padding: 10px 0; border-top: 1px solid var(--color-border); }
.vk-head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
.vk-state { color: var(--color-fg-muted, inherit); }
.vk-notice { color: var(--color-ok); }
.vk-error { color: var(--color-danger); overflow-wrap: anywhere; }
</style>
