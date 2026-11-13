<!-- Tenant settings -> Vendor split (owner t1 e837eeab): how new agent work
     is shared across Claude, Grok, Antigravity, Qwen, Mistral (spec 110) and
     Codex (OpenAI Codex CLI, spec 161; SPL-5454).
     First the split per task kind (spec 115 HUB-1, AgentSplitKinds), then
     the flat split below, the row for a kind the picker does not know.
     The six whole
     numbers sum to 100. They are a guideline, not a quota: nothing in the
     hub refuses a spawn that drifts. tenant.settings. -->
<template>
  <AgentSplitKinds v-if="allowed" />
  <SettingsSection id="tenant-split" :title="t('tenant_settings.split_title')" data-test="tenant-settings-split">
    <p v-if="denied" class="muted" role="alert" data-test="tenant-section-forbidden">{{ t('tenant_settings.forbidden') }}</p>
    <p v-else-if="loading" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="loadError" class="ts-error" role="alert">{{ loadError }}</p>
    <form v-else class="ts-form" @submit.prevent="save">
      <p class="muted ts-hint" data-test="tenant-split-note">{{ t('tenant_settings.split_note') }}</p>
      <p class="muted ts-hint">{{ t('tenant_settings.split_hint') }}</p>
      <div class="ts-split">
        <label class="ts-field">
          <span>{{ t('tenant_settings.split_claude') }}</span>
          <input v-model.number="claude" type="number" min="0" max="100" step="1" inputmode="numeric" data-test="tenant-split-claude">
        </label>
        <label class="ts-field">
          <span>{{ t('tenant_settings.split_grok') }}</span>
          <input v-model.number="grok" type="number" min="0" max="100" step="1" inputmode="numeric" data-test="tenant-split-grok">
        </label>
        <label class="ts-field">
          <span>{{ t('tenant_settings.split_agy') }}</span>
          <input v-model.number="agy" type="number" min="0" max="100" step="1" inputmode="numeric" data-test="tenant-split-agy">
        </label>
        <label class="ts-field">
          <span>{{ t('tenant_settings.split_qwen') }}</span>
          <input v-model.number="qwen" type="number" min="0" max="100" step="1" inputmode="numeric" data-test="tenant-split-qwen">
        </label>
        <label class="ts-field">
          <span>{{ t('tenant_settings.split_mistral') }}</span>
          <input v-model.number="mistral" type="number" min="0" max="100" step="1" inputmode="numeric" data-test="tenant-split-mistral">
        </label>
        <label class="ts-field">
          <span>{{ t('tenant_settings.split_codex') }}</span>
          <input v-model.number="codex" type="number" min="0" max="100" step="1" inputmode="numeric" data-test="tenant-split-codex">
        </label>
      </div>
      <p :class="sumOk ? 'muted ts-hint' : 'ts-error'" data-test="tenant-split-sum">{{ t('tenant_settings.split_sum', { n: sumText }) }}</p>
      <div class="ts-actions">
        <button type="submit" class="btn" :disabled="busy || !dirty || !sumOk" data-test="tenant-split-save">{{ t('tenant_settings.save') }}</button>
        <p v-if="notice" class="ts-notice" role="status" data-test="tenant-split-notice">{{ notice }}</p>
        <p v-if="error" class="ts-error" role="alert" data-test="tenant-split-error">{{ error }}</p>
      </div>
    </form>
  </SettingsSection>
</template>

<script setup lang="ts">
import AgentSplitKinds from '~/components/AgentSplitKinds.vue'
import SettingsSection from '~/components/SettingsSection.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useTenantSectionGate } from '~/composables/useTenantSectionGate'
import { normalizeTenantSettings, tenantSettingsErrorKey } from '~/utils/tenant-settings.mjs'
import type { TenantSettings } from '~/utils/tenant-settings.mjs'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

const stored = ref<TenantSettings | null>(null)
const claude = ref<number | string>(40)
const grok = ref<number | string>(50)
const agy = ref<number | string>(10)
const qwen = ref<number | string>(0)
const mistral = ref<number | string>(0)
const codex = ref<number | string>(0)
const loading = ref(true)
const loadError = ref('')
const busy = ref(false)
const error = ref('')
const notice = ref('')

function cell(v: number | string): number | null {
  if (v === '') return null
  const n = typeof v === 'number' ? v : Number(v)
  if (!Number.isInteger(n) || n < 0 || n > 100) return null
  return n
}

const parsed = computed(() => ({
  claude: cell(claude.value),
  grok: cell(grok.value),
  agy: cell(agy.value),
  qwen: cell(qwen.value),
  mistral: cell(mistral.value),
  codex: cell(codex.value),
}))

/** Every share parsed: the six numbers, or null while one is not 0..100. */
function shares(p: typeof parsed.value) {
  const { claude: c, grok: g, agy: a, qwen: q, mistral: m, codex: x } = p
  if (c === null || g === null || a === null || q === null || m === null || x === null) return null
  return { claude: c, grok: g, agy: a, qwen: q, mistral: m, codex: x }
}

const sum = computed(() => {
  const p = shares(parsed.value)
  if (!p) return null
  return p.claude + p.grok + p.agy + p.qwen + p.mistral + p.codex
})

const sumOk = computed(() => sum.value === 100)
const sumText = computed(() => (sum.value === null ? '—' : String(sum.value)))

const dirty = computed(() => {
  const s = stored.value
  const p = shares(parsed.value)
  if (!s || !p) return false
  const a = s.agentSplit
  return p.claude !== a.claude || p.grok !== a.grok || p.agy !== a.agy || p.qwen !== a.qwen || p.mistral !== a.mistral ||
    p.codex !== a.codex
})

function take(s: TenantSettings) {
  stored.value = s
  claude.value = s.agentSplit.claude
  grok.value = s.agentSplit.grok
  agy.value = s.agentSplit.agy
  qwen.value = s.agentSplit.qwen
  mistral.value = s.agentSplit.mistral
  codex.value = s.agentSplit.codex
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
  const p = shares(parsed.value)
  if (!s || busy.value || !sumOk.value || !p) return
  busy.value = true
  error.value = ''
  notice.value = ''
  try {
    take(normalizeTenantSettings(await api.patchTenantSettings({
      agent_split: p,
    })))
    notice.value = t('tenant_settings.saved')
  } catch (e) {
    error.value = t(tenantSettingsErrorKey(e))
  } finally {
    busy.value = false
  }
}

const { allowed, denied } = useTenantSectionGate('split', () => { void load() })
</script>

<style scoped>
.ts-form { display: flex; flex-direction: column; gap: 14px; }
.ts-hint { margin: 0; }
.ts-split { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 12px; max-width: 630px; }
.ts-field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.ts-field input {
  width: 100%;
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.ts-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.ts-notice { margin: 0; color: var(--color-ok); }
.ts-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .ts-split { grid-template-columns: 1fr 1fr; max-width: none; }
  .ts-field input, .ts-actions .btn { min-height: var(--tap, 44px); }
}
</style>
