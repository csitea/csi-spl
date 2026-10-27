<!-- One Agent keys row's controls (pages/tenant-settings/agent-keys.vue, spec
     127 8, spec 159 10): the key as a password field (qwen also its https
     base URL), Set or Replace, Remove after a second click, and Retry on an
     exhausted key. The typed key is handed to the page once and cleared at
     that moment, whatever the hub then answers (127 L12): it is never kept,
     never stored and never shown again. -->
<template>
  <form class="vkc" @submit.prevent="send">
    <label class="vkc-field">
      <span>{{ t(row.set ? 'tenant_settings.agent_keys.new_key' : 'tenant_settings.agent_keys.key') }}</span>
      <input
        v-model="key"
        type="password"
        autocomplete="new-password"
        spellcheck="false"
        :disabled="busy"
        data-test="vk-input"
      >
    </label>
    <label v-if="row.kind === 'qwen'" class="vkc-field">
      <span>{{ t('tenant_settings.agent_keys.base_url') }}</span>
      <input v-model="baseUrl" type="url" inputmode="url" :placeholder="row.baseUrl" :disabled="busy" data-test="vk-base-url">
    </label>
    <div class="vkc-actions">
      <button type="submit" class="btn" :disabled="busy || !key" data-test="vk-save">
        {{ t(row.set ? 'tenant_settings.agent_keys.replace' : 'tenant_settings.agent_keys.set') }}
      </button>
      <button v-if="row.set && row.exhausted" type="button" class="btn" :disabled="busy" data-test="vk-retry" @click="emit('retry', row.kind)">
        {{ t('tenant_settings.agent_keys.retry') }}
      </button>
      <template v-if="row.set">
        <button v-if="!asking" type="button" class="btn ghost" :disabled="busy" data-test="vk-remove" @click="asking = true">
          {{ t('tenant_settings.agent_keys.remove') }}
        </button>
        <template v-else>
          <span class="vkc-ask">{{ t('tenant_settings.agent_keys.remove_ask') }}</span>
          <button type="button" class="btn danger" :disabled="busy" data-test="vk-remove-confirm" @click="removeNow">
            {{ t('tenant_settings.agent_keys.remove_yes') }}
          </button>
          <button type="button" class="btn ghost" data-test="vk-remove-cancel" @click="asking = false">
            {{ t('tenant_settings.agent_keys.cancel') }}
          </button>
        </template>
      </template>
    </div>
  </form>
</template>

<script setup lang="ts">
import { vendorKeyPutBody } from '~/utils/vendor-keys.mjs'
import type { normalizeVendorKeys } from '~/utils/vendor-keys.mjs'

type Row = ReturnType<typeof normalizeVendorKeys>['rows'][number]

const props = defineProps<{ row: Row, busy: boolean }>()
const emit = defineEmits<{
  save: [kind: string, body: { key: string, base_url?: string } | null, error: string]
  remove: [kind: string]
  retry: [kind: string]
}>()
const { t } = useI18n({ useScope: 'global' })

const key = ref('')
const baseUrl = ref(props.row.baseUrl)
const asking = ref(false)

function send() {
  const out = vendorKeyPutBody(props.row.kind, key.value, baseUrl.value || props.row.baseUrl)
  if (out.error) {
    emit('save', props.row.kind, null, out.error)
    return
  }
  key.value = ''
  emit('save', props.row.kind, out.body ?? null, '')
}

function removeNow() {
  asking.value = false
  emit('remove', props.row.kind)
}
</script>

<style scoped>
.vkc { display: flex; flex-direction: column; gap: 8px; max-width: 525px; }
.vkc-field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.vkc-field input {
  width: 100%;
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.vkc-actions { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.vkc-ask { color: var(--color-danger); }
@media (max-width: 820px) {
  .vkc-field input, .vkc-actions .btn { min-height: var(--tap, 44px); }
}
</style>
