<!-- Tenant settings -> Vendor split -> Default model (spec 184 row W1,
     SPL-6725; owner HUM-10 msg 0d33aa83, Q1 bo, Q2 bo, N1): per vendor the
     model a new, rotated or restarted agent starts with, for every kind
     ('*') and, optionally, per task kind. The choices are the latest model
     list a box read from that vendor's CLI, with its time and CLI version; a
     typed model is taken too when it passes the syntax of spec 184 7.1.2
     (no space, no quote), which blocks Save before the hub's 400 bad_model.
     An empty cell reads as the cnf env.box.agent_model, else the CLI's own
     default. The reading is a display only: the launcher checks the model
     live at spawn. tenant.settings. -->
<template>
  <SettingsSection id="tenant-agent-models" :title="t('tenant_settings.models_title')" data-test="agent-models">
    <p v-if="loading" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="loadError" class="ts-error" role="alert">{{ loadError }}</p>
    <form v-else class="ts-form" @submit.prevent="save">
      <p class="muted ts-hint">{{ t('tenant_settings.models_hint') }}</p>
      <div class="am-wrap">
        <table class="am-table">
          <thead>
            <tr>
              <th scope="col">{{ t('tenant_settings.split_kind_col') }}</th>
              <th v-for="v in AGENT_SPLIT_KINDS" :key="v" scope="col">{{ t('tenant_settings.split_' + v) }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="k in AGENT_MODEL_KINDS" :key="k" :data-test="'agent-model-' + kindKey(k)">
              <th scope="row">{{ kindLabel(k) }}</th>
              <td v-for="v in AGENT_SPLIT_KINDS" :key="v">
                <input
                  v-model="edited[v][k]"
                  type="text" maxlength="80" spellcheck="false" autocomplete="off"
                  :list="'agent-models-' + v"
                  :placeholder="placeholder(v, k)"
                  :aria-label="kindLabel(k) + ' ' + t('tenant_settings.split_' + v)"
                  :aria-invalid="!agentModelValid(edited[v][k])"
                  :class="{ 'am-bad': !agentModelValid(edited[v][k]) }"
                  :data-test="'agent-model-' + kindKey(k) + '-' + v"
                  @input="notice = ''"
                >
              </td>
            </tr>
          </tbody>
        </table>
        <datalist v-for="v in AGENT_SPLIT_KINDS" :id="'agent-models-' + v" :key="v">
          <option v-for="m in readings[v]?.models || []" :key="m" :value="m" />
        </datalist>
      </div>
      <ul class="am-readings muted" data-test="agent-model-readings">
        <li v-for="v in AGENT_SPLIT_KINDS" :key="v" :data-test="'agent-model-reading-' + v">{{ readingText(v) }}</li>
      </ul>
      <p v-if="!valid" class="ts-error" role="alert" data-test="agent-models-bad">{{ t('tenant_settings.error.bad_model') }}</p>
      <div class="ts-actions">
        <button type="submit" class="btn" :disabled="busy || !dirty || !valid" data-test="agent-models-save">{{ t('tenant_settings.save') }}</button>
        <p v-if="notice" class="ts-notice" role="status" data-test="agent-models-notice">{{ notice }}</p>
        <p v-if="error" class="ts-error" role="alert" data-test="agent-models-error">{{ error }}</p>
      </div>
    </form>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { AGENT_MODEL_KINDS, AGENT_SPLIT_KINDS, agentModelReadingsOf, agentModelsPatchOf, agentModelValid, normalizeTenantSettings, tenantSettingsErrorKey } from '~/utils/tenant-settings.mjs'
import type { AgentModelReading, AgentModels } from '~/utils/tenant-settings.mjs'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()

const blank = (): AgentModels => Object.fromEntries(AGENT_SPLIT_KINDS.map((v) => [v, Object.fromEntries(AGENT_MODEL_KINDS.map((k) => [k, '']))]))
const stored = ref<AgentModels>(blank())
const edited = ref<AgentModels>(blank())
const readings = ref<Record<string, AgentModelReading>>({})
const loading = ref(true)
const loadError = ref('')
const busy = ref(false)
const error = ref('')
const notice = ref('')

/** '*' is not a data-test word: the every-kind row is "all". */
const kindKey = (k: string) => (k === '*' ? 'all' : k)
const kindLabel = (k: string) => t(k === '*' ? 'tenant_settings.models_kind_all' : 'tenant_settings.split_kind_' + k)

/** A kind cell left empty shows what it falls back to: the vendor's every-kind model, else the CLI default. */
function placeholder(v: string, k: string): string {
  const all = String(edited.value[v]?.['*'] ?? '').trim()
  return k !== '*' && all && agentModelValid(all) ? all : t('tenant_settings.models_cli_default')
}

function readingText(v: string): string {
  const vendor = t('tenant_settings.split_' + v)
  const r = readings.value[v]
  if (!r) return t('tenant_settings.models_no_reading', { vendor })
  const at = r.readAt.replace('T', ' ').slice(0, 16) + ' UTC'
  return t('tenant_settings.models_reading', { vendor, at, box: r.box, cli: r.cliVersion || '?' })
}

const valid = computed(() => AGENT_SPLIT_KINDS.every((v) => AGENT_MODEL_KINDS.every((k) => agentModelValid(edited.value[v][k]))))
const dirty = computed(() => AGENT_SPLIT_KINDS.some((v) => AGENT_MODEL_KINDS.some((k) => String(edited.value[v][k] ?? '').trim() !== (stored.value[v][k] ?? ''))))

function take(models: AgentModels) {
  const s = blank()
  for (const v of AGENT_SPLIT_KINDS) Object.assign(s[v], models[v] || {})
  stored.value = s
  edited.value = JSON.parse(JSON.stringify(s))
}

async function load() {
  try {
    take(normalizeTenantSettings(await api.getTenantSettings()).agentModels)
    loadError.value = ''
  } catch (e) {
    loadError.value = t(tenantSettingsErrorKey(e))
  } finally {
    loading.value = false
  }
  /* display only (N1): a hub without readings leaves every vendor "no reading yet" */
  try {
    readings.value = agentModelReadingsOf(await api.getAgentModelReadings())
  } catch {
    readings.value = {}
  }
}

async function save() {
  if (busy.value || !dirty.value || !valid.value) return
  busy.value = true
  error.value = ''
  notice.value = ''
  try {
    const patch = agentModelsPatchOf(stored.value, edited.value)
    if (patch) take(normalizeTenantSettings(await api.patchTenantSettings({ agent_models: patch })).agentModels)
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
.ts-hint { margin: 0; }
/* six text columns do not fit the card on a narrow screen: the table
   scrolls inside .am-wrap, never the page */
.am-wrap { max-width: 100%; overflow-x: auto; }
.am-table { border-collapse: collapse; font-size: 0.9em; }
.am-table th, .am-table td { padding: 4px 2px; text-align: left; vertical-align: middle; }
.am-table thead th { font-weight: 600; white-space: nowrap; font-size: 0.85em; }
.am-table tbody th { font-weight: 500; min-width: 6.5em; }
.am-table input {
  width: 7.5em;
  padding: 4px 4px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.am-table input.am-bad { border-color: var(--color-danger); }
.am-readings { margin: 0; padding-left: 1.2em; font-size: 0.85em; }
.ts-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.ts-notice { margin: 0; color: var(--color-ok); }
.ts-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .am-table input, .ts-actions .btn { min-height: var(--tap, 44px); }
}
</style>
