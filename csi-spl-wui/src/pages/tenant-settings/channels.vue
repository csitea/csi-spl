<!-- Tenant settings -> Channels (specs/046 §4.4): every channel of the
     tenant, the private ones the admin is not in too (names and counts only,
     never a message): visibility, members, agents, the no-fallback flag
     (SPL-997 FR-039), and Archive (the 041-style soft delete, behind a
     confirm). Default channels cannot be archived. tenant.settings. -->
<template>
  <SettingsSection id="tenant-channels" :title="t('tenant_settings.channels_title')" data-test="tenant-settings-channels">
    <p v-if="loading" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="loadError" class="ts-error" role="alert">{{ loadError }}</p>
    <div v-else class="ts-table-wrap">
      <table class="ts-table" data-test="tenant-channels-table">
        <thead>
          <tr>
            <th scope="col">{{ t('tenant_settings.col_channel') }}</th>
            <th scope="col">{{ t('tenant_settings.col_visibility') }}</th>
            <th scope="col" class="ts-num">{{ t('tenant_settings.col_members') }}</th>
            <th scope="col" class="ts-num">{{ t('tenant_settings.col_agents') }}</th>
            <th scope="col">{{ t('tenant_settings.col_fallback') }}</th>
            <th scope="col"><span class="sr-only">{{ t('tenant_settings.col_actions') }}</span></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="c in rows" :key="c.channel" data-test="tenant-channel-row" :data-channel="c.channel">
            <td class="ts-name">
              <span># {{ c.name }}</span>
              <span v-if="c.name !== c.channel" class="muted ts-id">{{ c.channel }}</span>
            </td>
            <td>{{ c.visibility === 'default' ? t('tenant_settings.visibility_default') : t('tenant_settings.visibility_members') }}</td>
            <td class="ts-num">{{ c.visibility === 'default' ? t('tenant_settings.everyone') : c.members }}</td>
            <td class="ts-num">{{ c.agents }}</td>
            <td>
              <label class="ts-check">
                <input
                  type="checkbox"
                  :checked="!c.noFallback"
                  :disabled="busy === c.channel"
                  data-test="tenant-channel-fallback"
                  @change="setFallback(c, !($event.target as HTMLInputElement).checked)"
                >
                <span>{{ c.noFallback ? t('tenant_settings.fallback_off') : t('tenant_settings.fallback_on') }}</span>
              </label>
            </td>
            <td class="ts-act">
              <button
                v-if="c.archivable"
                type="button"
                class="btn ghost ts-danger"
                :disabled="busy === c.channel"
                data-test="tenant-channel-archive"
                @click="target = c"
              >
                {{ t('tenant_settings.archive') }}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <p class="muted ts-hint">{{ t('tenant_settings.fallback_hint') }}</p>
    <p v-if="notice" class="ts-notice" role="status" data-test="tenant-channels-notice">{{ notice }}</p>
    <p v-if="error" class="ts-error" role="alert" data-test="tenant-channels-error">{{ error }}</p>
  </SettingsSection>

  <UiDialog
    :open="Boolean(target)"
    size="md"
    :title="t('tenant_settings.archive_confirm_title')"
    @update:open="(v: boolean) => { if (!v) target = null }"
  >
    <p data-test="tenant-channel-archive-text">{{ t('tenant_settings.archive_confirm', { name: target?.name || '' }) }}</p>
    <template #footer>
      <button type="button" class="btn ghost" data-test="tenant-channel-archive-cancel" @click="target = null">{{ t('common.cancel') }}</button>
      <button type="button" class="btn ts-danger" data-test="tenant-channel-archive-ok" @click="archive">{{ t('tenant_settings.archive') }}</button>
    </template>
  </UiDialog>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import UiDialog from '~/components/UiDialog.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { normalizeTenantChannels, tenantSettingsErrorKey } from '~/utils/tenant-settings.mjs'
import type { TenantChannel } from '~/utils/tenant-settings.mjs'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()

const rows = ref<TenantChannel[]>([])
const loading = ref(true)
const loadError = ref('')
const busy = ref('')
const error = ref('')
const notice = ref('')
const target = ref<TenantChannel | null>(null)

async function load() {
  try {
    rows.value = normalizeTenantChannels(await api.listTenantChannels())
    loadError.value = ''
  } catch (e) {
    loadError.value = t(tenantSettingsErrorKey(e))
  } finally {
    loading.value = false
  }
}

async function act(c: TenantChannel, job: () => Promise<unknown>, done: string) {
  if (busy.value) return
  busy.value = c.channel
  error.value = ''
  notice.value = ''
  try {
    await job()
    notice.value = done
  } catch (e) {
    error.value = t(tenantSettingsErrorKey(e))
  } finally {
    busy.value = ''
    await load()
  }
}

function setFallback(c: TenantChannel, off: boolean) {
  void act(c, () => api.setTenantChannelNoFallback(c.channel, off), t('tenant_settings.saved'))
}

function archive() {
  const c = target.value
  target.value = null
  if (c) void act(c, () => api.archiveTenantChannel(c.channel), t('tenant_settings.archived', { name: c.name }))
}

watch(() => session.state, (st) => {
  if (st === 'in' || api.mock) void load()
}, { immediate: true })
</script>

<style scoped>
.ts-table-wrap { overflow-x: auto; max-width: 100%; }
.ts-table { width: 100%; border-collapse: collapse; font-size: 0.875rem; }
.ts-table th, .ts-table td { padding: 6px 8px; text-align: start; border-bottom: 1px solid var(--color-border); vertical-align: middle; }
.ts-table th { font-weight: 600; color: var(--color-muted); font-size: 0.8125rem; }
.ts-num { text-align: end; }
.ts-name { display: flex; flex-direction: column; min-width: 0; overflow-wrap: anywhere; }
.ts-id { font-size: 0.75rem; }
.ts-check { display: inline-flex; align-items: center; gap: 6px; }
.ts-act { text-align: end; }
.ts-danger { color: var(--color-danger); border-color: var(--color-danger); }
.ts-hint { margin: 10px 0 0; }
.ts-notice { margin: 8px 0 0; color: var(--color-ok); }
.ts-error { margin: 8px 0 0; color: var(--color-danger); overflow-wrap: anywhere; }
.sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
/* phones: one card per channel instead of a wide table */
@media (max-width: 820px) {
  .ts-table thead { display: none; }
  .ts-table, .ts-table tbody, .ts-table tr, .ts-table td { display: block; width: 100%; }
  .ts-table tr { border-bottom: 1px solid var(--color-border); padding: 8px 0; }
  .ts-table td { border: 0; padding: 2px 0; text-align: start; }
  .ts-check { min-height: var(--tap, 44px); }
  .ts-act .btn { min-height: var(--tap, 44px); }
}
</style>
