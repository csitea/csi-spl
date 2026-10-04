<!-- Fleet load (rdb 0118): low / high as a percent of a box's cores, and the
     order the boxes take a new agent. GET/PATCH /v1/operator/fleet-load.
     Shown only when that GET succeeds. A 403 operator.workspaces hides the
     card (the nav entry is hidden by the same probe in tenant-settings.vue).
     A reset sends JSON null, which is the hub's "back to the default". -->
<template>
  <div data-test="tenant-fleet-root" :data-state="state">
    <p v-if="state === 'loading'" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="state === 'error'" class="fl-error" role="alert" data-test="tenant-fleet-load-error">{{ loadError }}</p>
    <SettingsSection
      v-else-if="state === 'ready' && view"
      id="tenant-fleet-load"
      :title="t('tenant_settings.fleet_load_title')"
      data-test="tenant-settings-fleet-load"
    >
      <p class="muted fl-hint">{{ t('tenant_settings.fleet_load_hint') }}</p>
      <div class="fl-field">
        <label for="tenant-fleet-low">{{ t('tenant_settings.fleet_load_low') }}</label>
        <input
          id="tenant-fleet-low"
          :value="low"
          type="number"
          min="1"
          max="99"
          step="1"
          inputmode="numeric"
          autocomplete="off"
          data-test="tenant-fleet-low"
          :data-using-default="lowUsesDefault ? '1' : '0'"
          @input="editLow(($event.target as HTMLInputElement).value)"
        >
        <small class="muted" data-test="tenant-fleet-low-default">{{ t('tenant_settings.fleet_load_default', { n: view.defaults.low }) }}</small>
        <small v-if="lowUsesDefault" class="muted" data-test="tenant-fleet-low-using">{{ t('tenant_settings.fleet_load_using_default') }}</small>
        <button type="button" class="btn ghost" :disabled="saving || lowUsesDefault" data-test="tenant-fleet-low-reset" @click="resetToDefault('low')">
          {{ t('tenant_settings.fleet_load_reset') }}
        </button>
      </div>
      <div class="fl-field">
        <label for="tenant-fleet-high">{{ t('tenant_settings.fleet_load_high') }}</label>
        <input
          id="tenant-fleet-high"
          :value="high"
          type="number"
          min="2"
          max="100"
          step="1"
          inputmode="numeric"
          autocomplete="off"
          data-test="tenant-fleet-high"
          :data-using-default="highUsesDefault ? '1' : '0'"
          @input="editHigh(($event.target as HTMLInputElement).value)"
        >
        <small class="muted" data-test="tenant-fleet-high-default">{{ t('tenant_settings.fleet_load_default', { n: view.defaults.high }) }}</small>
        <small v-if="highUsesDefault" class="muted" data-test="tenant-fleet-high-using">{{ t('tenant_settings.fleet_load_using_default') }}</small>
        <button type="button" class="btn ghost" :disabled="saving || highUsesDefault" data-test="tenant-fleet-high-reset" @click="resetToDefault('high')">
          {{ t('tenant_settings.fleet_load_reset') }}
        </button>
      </div>

      <div class="fl-field">
        <span id="tenant-fleet-boxes-label">{{ t('tenant_settings.fleet_load_boxes') }}</span>
        <small class="muted">{{ t('tenant_settings.fleet_load_boxes_hint') }}</small>
        <small class="muted" data-test="tenant-fleet-order-default">{{ t('tenant_settings.fleet_load_boxes_default') }}</small>
        <small v-if="orderUsesDefault" class="muted" data-test="tenant-fleet-order-using">{{ t('tenant_settings.fleet_load_using_default') }}</small>
        <ol v-if="boxes.length" class="fl-list" data-test="tenant-fleet-boxes" aria-labelledby="tenant-fleet-boxes-label">
          <li v-for="(id, i) in boxes" :key="id" class="fl-row" data-test="tenant-fleet-box" :data-box="id">
            <span class="fl-row__n">{{ i + 1 }}.</span>
            <code class="fl-row__id">{{ id }}</code>
            <button
              type="button"
              class="icon-btn"
              :disabled="i === 0 || saving"
              :title="t('tenant_settings.move_up')"
              :aria-label="t('tenant_settings.move_up') + ' ' + id"
              data-test="tenant-fleet-up"
              @click="move(i, -1)"
            >
              <UiIcon name="chevron-up" :size="16" />
            </button>
            <button
              type="button"
              class="icon-btn"
              :disabled="i === boxes.length - 1 || saving"
              :title="t('tenant_settings.move_down')"
              :aria-label="t('tenant_settings.move_down') + ' ' + id"
              data-test="tenant-fleet-down"
              @click="move(i, 1)"
            >
              <UiIcon name="chevron-down" :size="16" />
            </button>
            <button
              type="button"
              class="icon-btn"
              :disabled="saving"
              :title="t('tenant_settings.remove')"
              :aria-label="t('tenant_settings.remove') + ' ' + id"
              data-test="tenant-fleet-remove"
              @click="removeAt(i)"
            >
              <UiIcon name="x" :size="16" />
            </button>
          </li>
        </ol>
        <p v-else class="muted" data-test="tenant-fleet-boxes-empty">{{ t('tenant_settings.fleet_load_boxes_empty') }}</p>
        <div class="fl-add">
          <input
            v-model="candidate"
            type="text"
            list="tenant-fleet-suggest"
            maxlength="32"
            autocomplete="off"
            spellcheck="false"
            :placeholder="t('tenant_settings.fleet_load_box_placeholder')"
            :aria-label="t('tenant_settings.fleet_load_box_placeholder')"
            data-test="tenant-fleet-input"
            @keydown.enter.prevent="addBox"
          >
          <datalist id="tenant-fleet-suggest">
            <option v-for="id in offer" :key="id" :value="id" />
          </datalist>
          <button type="button" class="btn ghost" :disabled="saving || !candidate.trim()" data-test="tenant-fleet-add" @click="addBox">
            {{ t('tenant_settings.add') }}
          </button>
          <button type="button" class="btn ghost" :disabled="saving || orderUsesDefault" data-test="tenant-fleet-order-reset" @click="resetToDefault('order')">
            {{ t('tenant_settings.fleet_load_reset') }}
          </button>
        </div>
      </div>

      <div class="fl-actions">
        <button type="button" class="btn" :disabled="saving || !dirty" data-test="tenant-fleet-save" @click="save">
          {{ t('tenant_settings.save') }}
        </button>
        <p v-if="notice" class="fl-notice" role="status" data-test="tenant-fleet-notice">{{ notice }}</p>
        <p v-if="formError" class="fl-error" role="alert" data-test="tenant-fleet-form-error">{{ formError }}</p>
        <p v-if="status" class="fl-error" role="alert" data-test="tenant-fleet-error">{{ status }}</p>
      </div>
    </SettingsSection>
  </div>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { useSettingSave } from '~/composables/useSettingSave'
import { moveItem } from '~/utils/tenant-settings.mjs'
import {
  FLEET_BOX_MAX,
  fleetLoadForbidden,
  fleetLoadPatchBody,
  fleetLoadStatusDetail,
  normalizeFleetLoad,
  suggestFleetBoxes,
  validFleetBox,
} from '~/utils/fleet-load.mjs'
import type { FleetLoadView } from '~/utils/fleet-load.mjs'

type FleetApi = {
  mock: boolean
  getFleetLoad: () => Promise<unknown>
  patchFleetLoad: (patch: Record<string, unknown>) => Promise<unknown>
  boxStats: (opts?: { since?: string }) => Promise<unknown>
}

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi() as unknown as FleetApi
const session = useSessionStore()
const { saving, status, run } = useSettingSave()

const state = ref<'loading' | 'forbidden' | 'error' | 'ready'>('loading')
const loadError = ref('')
const view = ref<FleetLoadView | null>(null)
const low = ref<number | ''>(50)
const high = ref<number | ''>(75)
const boxes = ref<string[]>([])
const resetLow = ref(false)
const resetHigh = ref(false)
const resetOrder = ref(false)
const candidate = ref('')
const suggestions = ref<string[]>([])
const notice = ref('')
const formError = ref('')

const offer = computed(() => suggestions.value.filter((id) => !boxes.value.includes(id)))

const lowUsesDefault = computed(() => {
  const s = view.value
  if (!s) return false
  if (resetLow.value) return true
  return s.stored.low == null && Number(low.value) === s.defaults.low
})
const highUsesDefault = computed(() => {
  const s = view.value
  if (!s) return false
  if (resetHigh.value) return true
  return s.stored.high == null && Number(high.value) === s.defaults.high
})
const orderUsesDefault = computed(() => {
  const s = view.value
  if (!s) return false
  if (resetOrder.value) return true
  return s.stored.boxOrder == null && boxes.value.length === 0
})
const dirty = computed(() => {
  const s = view.value
  if (!s) return false
  return Object.keys(fleetLoadPatchBody(s, draft())).length > 0
})

function draft() {
  return {
    low: Number(low.value),
    high: Number(high.value),
    boxOrder: boxes.value.slice(),
    resetLow: resetLow.value,
    resetHigh: resetHigh.value,
    resetOrder: resetOrder.value,
  }
}

function take(next: FleetLoadView) {
  view.value = next
  low.value = next.low
  high.value = next.high
  boxes.value = next.boxOrder.slice()
  resetLow.value = false
  resetHigh.value = false
  resetOrder.value = false
}

function editLow(raw: string) {
  resetLow.value = false
  low.value = raw === '' ? '' : Number(raw)
}
function editHigh(raw: string) {
  resetHigh.value = false
  high.value = raw === '' ? '' : Number(raw)
}

function resetToDefault(which: 'low' | 'high' | 'order') {
  const s = view.value
  if (!s) return
  formError.value = ''
  if (which === 'low') {
    low.value = s.defaults.low
    resetLow.value = true
  } else if (which === 'high') {
    high.value = s.defaults.high
    resetHigh.value = true
  } else {
    boxes.value = []
    resetOrder.value = true
  }
}

function move(i: number, delta: number) {
  boxes.value = moveItem(boxes.value, i, delta)
  resetOrder.value = false
}
function removeAt(i: number) {
  boxes.value = boxes.value.filter((_, j) => j !== i)
  resetOrder.value = false
}
function addBox() {
  const id = candidate.value.trim().toLowerCase()
  formError.value = ''
  if (!validFleetBox(id)) {
    formError.value = t('tenant_settings.fleet_load_bad_box')
    return
  }
  if (boxes.value.includes(id)) {
    candidate.value = ''
    return
  }
  if (boxes.value.length >= FLEET_BOX_MAX) {
    formError.value = t('tenant_settings.fleet_load_full')
    return
  }
  boxes.value = boxes.value.concat(id)
  resetOrder.value = false
  candidate.value = ''
}

async function persist(): Promise<{ ok: boolean, out?: { error: string, detail: string }, detail?: string }> {
  const s = view.value
  if (!s) return { ok: false }
  notice.value = ''
  const body = fleetLoadPatchBody(s, draft())
  if (Object.keys(body).length === 0) return { ok: true }
  try {
    take(normalizeFleetLoad(await api.patchFleetLoad(body)))
    notice.value = t('tenant_settings.saved')
    return { ok: true }
  } catch (e) {
    const detail = fleetLoadStatusDetail(e)
    const token = (e as { token?: string }).token || 'failed'
    return { ok: false, out: { error: token, detail }, detail }
  }
}

async function save() {
  let detail = ''
  let ran = false
  await run(async () => {
    ran = true
    const res = await persist()
    detail = res.detail || ''
    return res
  })
  if (!ran && api.mock) {
    const res = await persist()
    if (!res.ok) status.value = res.detail || t('settings.language.failed')
    return
  }
  if (detail) status.value = detail
}

let seq = 0
async function load() {
  const mine = ++seq
  state.value = 'loading'
  try {
    const body = normalizeFleetLoad(await api.getFleetLoad())
    if (mine !== seq) return
    take(body)
    state.value = 'ready'
    loadError.value = ''
    try {
      suggestions.value = suggestFleetBoxes(await api.boxStats({ since: '7d' }))
    } catch {
      if (mine === seq) suggestions.value = []
    }
  } catch (e) {
    if (mine !== seq) return
    if (fleetLoadForbidden(e)) {
      state.value = 'forbidden'
      view.value = null
      return
    }
    const err = e as { detail?: string }
    loadError.value = err.detail || t('tenant_settings.error.generic')
    state.value = 'error'
  }
}

watch(() => session.state, (st) => {
  if (st === 'in' || api.mock) void load()
}, { immediate: true })
</script>

<style scoped>
.fl-hint { margin: 0 0 12px; }
.fl-field { display: flex; flex-direction: column; align-items: flex-start; gap: 4px; min-width: 0; margin-bottom: 14px; }
.fl-field input[type="number"],
.fl-add input {
  width: 12em;
  max-width: 100%;
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.fl-list { list-style: none; margin: 4px 0; padding: 0; display: flex; flex-direction: column; gap: 2px; max-width: 100%; }
.fl-row { display: flex; align-items: center; gap: 8px; min-height: 36px; min-width: 0; }
.fl-row__n { width: 2.5ch; color: var(--color-muted); flex: none; }
.fl-row__id { min-width: 0; overflow-wrap: anywhere; }
.fl-add { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; max-width: 100%; }
.fl-add input { flex: 1 1 10em; }
.fl-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.fl-notice { margin: 0; color: var(--color-ok); }
.fl-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .fl-field input[type="number"],
  .fl-add input { width: 100%; min-height: var(--tap, 44px); }
  .fl-row { min-height: var(--tap, 44px); }
  .fl-row .icon-btn { width: var(--tap, 44px); height: var(--tap, 44px); }
  .fl-actions .btn, .fl-add .btn, .fl-field .btn { min-height: var(--tap, 44px); }
}
</style>
