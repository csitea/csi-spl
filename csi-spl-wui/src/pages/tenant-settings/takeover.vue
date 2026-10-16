<!-- Tenant settings -> Agent takeover (SPL-2115, owner t1 35beee77): per task
     kind, the order in which the vendors take over a failed task on the same
     branch, and how many failures each vendor is allowed before the next one
     takes over. Reorder with the up / down buttons, add or remove a vendor,
     set the number; Save sends the changed kinds, Reset to defaults drops
     every kind the workspace set. A row the hub would refuse (no vendor,
     agy or qwen in Secrets, a number out of range) names the rule and blocks
     Save. tenant.settings. -->
<template>
  <SettingsSection id="tenant-takeover" :title="t('takeover.title')" data-test="takeover">
    <p v-if="loading" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="loadError" class="ts-error" role="alert">{{ loadError }}</p>
    <form v-else class="ts-form" @submit.prevent="save">
      <p class="muted ts-hint">{{ t('takeover.hint') }}</p>
      <ul class="tk-rows">
        <li v-for="r in rows" :key="r.kind" class="tk-row" :data-test="'takeover-' + r.kind">
          <div class="tk-head">
            <span class="tk-kind">{{ t('tenant_settings.split_kind_' + r.kind) }}</span>
            <span v-if="!r.set && !r.dirty" class="tk-sub muted" :data-test="'takeover-' + r.kind + '-default'">{{ t('tenant_settings.split_default') }}</span>
          </div>
          <ol class="tk-order" :aria-label="t('tenant_settings.split_kind_' + r.kind) + ': ' + t('takeover.order_col')" :data-test="'takeover-' + r.kind + '-order'">
            <li v-for="(v, i) in r.order" :key="v" class="tk-vendor" :data-vendor="v">
              <span class="tk-n">{{ i + 1 }}</span>
              <span class="tk-name">{{ t('tenant_settings.split_' + v) }}</span>
              <button
                type="button" class="icon-btn" :disabled="busy || i === 0"
                :aria-label="t('takeover.up', { name: t('tenant_settings.split_' + v) })"
                :title="t('takeover.up', { name: t('tenant_settings.split_' + v) })"
                :data-test="'takeover-' + r.kind + '-up-' + v"
                @click="move(r, i, -1)"
              ><UiIcon name="chevron-up" :size="16" /></button>
              <button
                type="button" class="icon-btn" :disabled="busy || i === r.order.length - 1"
                :aria-label="t('takeover.down', { name: t('tenant_settings.split_' + v) })"
                :title="t('takeover.down', { name: t('tenant_settings.split_' + v) })"
                :data-test="'takeover-' + r.kind + '-down-' + v"
                @click="move(r, i, 1)"
              ><UiIcon name="chevron-down" :size="16" /></button>
              <button
                type="button" class="icon-btn" :disabled="busy || r.order.length === 1"
                :aria-label="t('takeover.remove', { name: t('tenant_settings.split_' + v) })"
                :title="t('takeover.remove', { name: t('tenant_settings.split_' + v) })"
                :data-test="'takeover-' + r.kind + '-remove-' + v"
                @click="remove(r, i)"
              ><UiIcon name="x" :size="16" /></button>
            </li>
          </ol>
          <div class="tk-foot">
            <select
              v-if="takeoverAddable(r.kind, r.order).length"
              :value="''" :disabled="busy"
              :aria-label="t('tenant_settings.split_kind_' + r.kind) + ': ' + t('takeover.add')"
              :data-test="'takeover-' + r.kind + '-add'"
              @change="add(r, $event)"
            >
              <option value="" disabled>{{ t('takeover.add') }}</option>
              <option v-for="v in takeoverAddable(r.kind, r.order)" :key="v" :value="v">{{ t('tenant_settings.split_' + v) }}</option>
            </select>
            <label class="tk-failures">
              <span>{{ t('takeover.failures_col') }}</span>
              <input
                v-model.number="r.maxFailures"
                type="number" :min="TAKEOVER_MAX_FAILURES_MIN" :max="TAKEOVER_MAX_FAILURES_MAX" step="1" inputmode="numeric"
                :disabled="busy"
                :data-test="'takeover-' + r.kind + '-failures'"
                @input="touch(r)"
              >
            </label>
          </div>
          <p v-if="ruleOf(r)" class="ts-error" role="alert" :data-test="'takeover-' + r.kind + '-rule'">
            {{ t('takeover.rule_' + ruleOf(r), { min: TAKEOVER_MAX_FAILURES_MIN, max: TAKEOVER_MAX_FAILURES_MAX }) }}
          </p>
        </li>
      </ul>
      <div class="ts-actions">
        <button type="submit" class="btn" :disabled="busy || !dirty || !valid" data-test="takeover-save">{{ t('tenant_settings.save') }}</button>
        <button type="button" class="btn ghost" :disabled="busy || !anySet" data-test="takeover-reset" @click="resetAll">{{ t('takeover.reset_all') }}</button>
        <p v-if="notice" class="ts-notice" role="status" data-test="takeover-notice">{{ notice }}</p>
        <p v-if="error" class="ts-error" role="alert" data-test="takeover-error">{{ error }}</p>
      </div>
      <p class="sr-only" role="status" aria-live="polite">{{ announce }}</p>
    </form>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import {
  TAKEOVER_KINDS, TAKEOVER_MAX_FAILURES_MAX, TAKEOVER_MAX_FAILURES_MIN,
  normalizeTakeoverLadder, takeoverAddable, takeoverErrorCode, takeoverMove, takeoverRule,
} from '~/utils/takeover-ladder.mjs'
import type { TakeoverRow } from '~/utils/takeover-ladder.mjs'

type EditRow = { kind: string, order: string[], maxFailures: number | string, set: boolean, dirty: boolean }

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()
// The key literals live here, not in the util: it is reachable from the first screen.
const ERROR_KEYS = {
  forbidden: 'takeover.error_forbidden',
  bad_ladder: 'takeover.error_bad_ladder',
  generic: 'takeover.error_generic',
} as const
const errorText = (e: unknown) => t(ERROR_KEYS[takeoverErrorCode(e)])

const rows = ref<EditRow[]>([])
const loading = ref(true)
const loadError = ref('')
const busy = ref(false)
const error = ref('')
const notice = ref('')
const announce = ref('')

const failuresOf = (r: EditRow) => (r.maxFailures === '' ? NaN : Number(r.maxFailures))
const ruleOf = (r: EditRow) => takeoverRule(r.kind, r.order, failuresOf(r))
const dirty = computed(() => rows.value.some((r) => r.dirty))
const valid = computed(() => rows.value.every((r) => !r.dirty || !ruleOf(r)))
const anySet = computed(() => rows.value.some((r) => r.set))

function touch(r: EditRow) {
  r.dirty = true
  notice.value = ''
}

function move(r: EditRow, i: number, delta: number) {
  const v = r.order[i]
  r.order = takeoverMove(r.order, i, delta)
  touch(r)
  announce.value = t('takeover.moved', { name: t('tenant_settings.split_' + v), n: r.order.indexOf(v) + 1 })
}

function remove(r: EditRow, i: number) {
  r.order = r.order.filter((_, j) => j !== i)
  touch(r)
}

function add(r: EditRow, ev: Event) {
  const el = ev.target as HTMLSelectElement
  const v = el.value
  el.value = ''
  if (!v || r.order.includes(v)) return
  r.order = [...r.order, v]
  touch(r)
}

function take(list: TakeoverRow[]) {
  rows.value = list.map((k) => ({ kind: k.kind, order: k.order.slice(), maxFailures: k.maxFailures, set: k.set, dirty: false }))
}

async function load() {
  try {
    take(normalizeTakeoverLadder(await api.getTakeoverLadder()))
    loadError.value = ''
  } catch (e) {
    loadError.value = errorText(e)
  } finally {
    loading.value = false
  }
}

async function send(kinds: Record<string, { order: string[], max_failures: number } | null>) {
  busy.value = true
  error.value = ''
  notice.value = ''
  try {
    take(normalizeTakeoverLadder(await api.putTakeoverLadder(kinds)))
    notice.value = t('tenant_settings.saved')
  } catch (e) {
    error.value = errorText(e)
  } finally {
    busy.value = false
  }
}

async function save() {
  if (busy.value || !dirty.value || !valid.value) return
  const kinds: Record<string, { order: string[], max_failures: number }> = {}
  for (const r of rows.value) {
    if (r.dirty) kinds[r.kind] = { order: r.order.slice(), max_failures: failuresOf(r) }
  }
  await send(kinds)
}

async function resetAll() {
  if (busy.value || !anySet.value) return
  await send(Object.fromEntries(TAKEOVER_KINDS.map((k) => [k, null])))
}

watch(() => session.state, (st) => {
  if (st === 'in' || api.mock) void load()
}, { immediate: true })
</script>

<style scoped>
.ts-form { display: flex; flex-direction: column; gap: 14px; }
.ts-hint { margin: 0; }
.tk-rows { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 12px; }
.tk-row {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 10px 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm, 8px);
  min-width: 0;
}
.tk-head { display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; }
.tk-kind { font-weight: 600; }
.tk-sub { font-size: 0.85em; }
.tk-order { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 6px; }
.tk-vendor {
  display: inline-flex;
  align-items: center;
  gap: 2px;
  padding: 2px 4px 2px 8px;
  background: var(--color-bg-2);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm, 8px);
}
.tk-n { font-variant-numeric: tabular-nums; color: var(--color-muted); margin-inline-end: 4px; }
.tk-name { margin-inline-end: 4px; }
.tk-foot { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.tk-failures { display: inline-flex; align-items: center; gap: 6px; }
.tk-failures input { width: 4.2em; }
.tk-foot select, .tk-failures input {
  padding: 4px 6px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.ts-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.ts-notice { margin: 0; color: var(--color-ok); }
.ts-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .tk-foot select, .tk-failures input, .ts-actions .btn { min-height: var(--tap, 44px); }
  .tk-vendor .icon-btn { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
}
</style>
