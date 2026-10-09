<!-- Tenant settings -> Vendor split, per task kind (spec 115 HUB-1, rdb 0163):
     one row per task kind, its five vendor weights out of 100 and its
     backup. The main (the highest weight) is shown, not chosen. A row that
     breaks a spec 115 section 2 rule names the rule and blocks Save; the hub
     refuses the same rows. A kind the workspace has not set shows its
     default; Reset drops a set kind back to it. tenant.settings. -->
<template>
  <SettingsSection id="tenant-split-kinds" :title="t('tenant_settings.split_kinds_title')" data-test="split-kinds">
    <p v-if="loading" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="loadError" class="ts-error" role="alert">{{ loadError }}</p>
    <form v-else class="ts-form" @submit.prevent="save">
      <p class="muted ts-hint">{{ t('tenant_settings.split_kinds_hint') }}</p>
      <div class="sk-wrap">
        <table class="sk-table">
          <thead>
            <tr>
              <th scope="col">{{ t('tenant_settings.split_kind_col') }}</th>
              <th v-for="v in AGENT_SPLIT_KINDS" :key="v" scope="col">{{ t('tenant_settings.split_' + v) }}</th>
              <th scope="col">{{ t('tenant_settings.split_backup') }}</th>
              <th scope="col">{{ t('tenant_settings.split_main') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in rows" :key="r.kind" :data-test="'split-kind-' + r.kind">
              <th scope="row">
                {{ t('tenant_settings.split_kind_' + r.kind) }}
                <span v-if="!r.set && !r.dirty" class="sk-sub muted">{{ t('tenant_settings.split_default') }}</span>
                <button v-else-if="r.set && !r.dirty" type="button" class="sk-sub sk-reset" :disabled="busy" :data-test="'split-kind-' + r.kind + '-reset'" @click="reset(r.kind)">{{ t('tenant_settings.split_reset') }}</button>
              </th>
              <td v-for="v in AGENT_SPLIT_KINDS" :key="v">
                <input
                  v-model.number="r.weights[v]"
                  type="number" min="0" max="100" step="1" inputmode="numeric"
                  :aria-label="t('tenant_settings.split_kind_' + r.kind) + ' ' + t('tenant_settings.split_' + v)"
                  :data-test="'split-kind-' + r.kind + '-' + v"
                  @input="touch(r)"
                >
              </td>
              <td>
                <select v-model="r.backup" :aria-label="t('tenant_settings.split_kind_' + r.kind) + ' ' + t('tenant_settings.split_backup')" :data-test="'split-kind-' + r.kind + '-backup'" @change="touch(r)">
                  <option v-for="v in AGENT_SPLIT_KINDS" :key="v" :value="v">{{ t('tenant_settings.split_' + v) }}</option>
                </select>
              </td>
              <td :data-test="'split-kind-' + r.kind + '-main'">
                <span v-if="ruleOf(r)" class="ts-error" role="alert">{{ ruleText(r) }}</span>
                <span v-else>{{ t('tenant_settings.split_' + mainOf(r)) }}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div class="ts-actions">
        <button type="submit" class="btn" :disabled="busy || !dirty || !valid" data-test="split-kinds-save">{{ t('tenant_settings.save') }}</button>
        <p v-if="notice" class="ts-notice" role="status" data-test="split-kinds-notice">{{ notice }}</p>
        <p v-if="error" class="ts-error" role="alert" data-test="split-kinds-error">{{ error }}</p>
      </div>
    </form>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { AGENT_SPLIT_KINDS, normalizeAgentSplitKinds, splitKindRule, splitMainOf, tenantSettingsErrorKey } from '~/utils/tenant-settings.mjs'
import type { SplitKindRow } from '~/utils/tenant-settings.mjs'

type EditRow = { kind: string, weights: Record<string, number | string>, backup: string, set: boolean, dirty: boolean }

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()

const rows = ref<EditRow[]>([])
const loading = ref(true)
const loadError = ref('')
const busy = ref(false)
const error = ref('')
const notice = ref('')

/** The row's weights as numbers; a blank or non-integer cell is -1 (the sum rule names it). */
function numbers(r: EditRow): Record<string, number> {
  const out: Record<string, number> = {}
  for (const v of AGENT_SPLIT_KINDS) {
    const raw = r.weights[v]
    const n = raw === '' ? NaN : Number(raw)
    out[v] = Number.isInteger(n) ? n : -1
  }
  return out
}

const ruleOf = (r: EditRow) => splitKindRule(r.kind, numbers(r), r.backup)
const mainOf = (r: EditRow) => splitMainOf(numbers(r))

function ruleText(r: EditRow): string {
  const rule = ruleOf(r)
  if (rule === 'sum') {
    const n = Object.values(numbers(r))
    return t('tenant_settings.split_sum', { n: n.some((x) => x < 0) ? '—' : String(n.reduce((a, b) => a + b, 0)) })
  }
  return t('tenant_settings.split_rule_' + rule)
}

const dirty = computed(() => rows.value.some((r) => r.dirty))
const valid = computed(() => rows.value.every((r) => !r.dirty || !ruleOf(r)))

function touch(r: EditRow) {
  r.dirty = true
  notice.value = ''
}

function take(list: SplitKindRow[]) {
  rows.value = list.map((k) => ({ kind: k.kind, weights: { ...k.weights }, backup: k.backup, set: k.set, dirty: false }))
}

async function load() {
  try {
    take(normalizeAgentSplitKinds(await api.getAgentSplit()))
    loadError.value = ''
  } catch (e) {
    loadError.value = t(tenantSettingsErrorKey(e))
  } finally {
    loading.value = false
  }
}

async function send(kinds: Record<string, { weights: Record<string, number>, backup: string } | null>) {
  busy.value = true
  error.value = ''
  notice.value = ''
  try {
    take(normalizeAgentSplitKinds(await api.patchAgentSplit(kinds)))
    notice.value = t('tenant_settings.saved')
  } catch (e) {
    error.value = t(tenantSettingsErrorKey(e))
  } finally {
    busy.value = false
  }
}

async function save() {
  if (busy.value || !dirty.value || !valid.value) return
  const kinds: Record<string, { weights: Record<string, number>, backup: string }> = {}
  for (const r of rows.value) {
    if (r.dirty) kinds[r.kind] = { weights: numbers(r), backup: r.backup }
  }
  await send(kinds)
}

async function reset(kind: string) {
  if (busy.value) return
  await send({ [kind]: null })
}

watch(() => session.state, (st) => {
  if (st === 'in' || api.mock) void load()
}, { immediate: true })
</script>

<style scoped>
.ts-form { display: flex; flex-direction: column; gap: 14px; }
.ts-hint { margin: 0; }
.sk-wrap { max-width: 100%; overflow-x: auto; }
.sk-table { border-collapse: collapse; font-size: 0.9em; }
.sk-table th, .sk-table td { padding: 4px 4px; text-align: left; vertical-align: middle; }
.sk-table thead th { font-weight: 600; white-space: nowrap; }
.sk-table tbody th { font-weight: 500; min-width: 7em; }
.sk-sub { display: block; font-size: 0.85em; font-weight: 400; }
.sk-reset {
  padding: 0;
  background: none;
  border: 0;
  color: var(--color-accent);
  text-decoration: underline;
  cursor: pointer;
}
.sk-table input {
  width: 4.2em;
  padding: 4px 6px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.sk-table select {
  padding: 4px 6px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.ts-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.ts-notice { margin: 0; color: var(--color-ok); }
.ts-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .sk-table input, .sk-table select, .ts-actions .btn { min-height: var(--tap, 44px); }
}
</style>
