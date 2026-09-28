<!-- Tenant settings -> Agents (specs/046 §4.3): the agents seated in the
     tenant with their online state (GET /v1/view/roster), and the fallback
     responder list (SPL-997): the first online one takes a human post no
     other agent hears. tenant.settings. -->
<template>
  <SettingsSection id="tenant-agents" :title="t('tenant_settings.agents_title')" data-test="tenant-settings-agents">
    <p v-if="loading" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="loadError" class="ts-error" role="alert">{{ loadError }}</p>
    <template v-else>
      <p v-if="!seats.length" class="muted" data-test="tenant-agents-empty">{{ t('tenant_settings.agents_empty') }}</p>
      <ul v-else class="ts-list" data-test="tenant-agents-list">
        <li v-for="s in seats" :key="s.id + '@' + s.box" class="ts-row" data-test="tenant-agent-row" :data-agent="s.id">
          <span class="ts-dot" :class="{ 'ts-dot--on': s.online }" :title="s.online ? t('tenant_settings.online') : t('tenant_settings.offline')" />
          <code class="ts-row__main">{{ s.id }}</code>
          <span class="muted ts-row__sub">{{ s.box }}</span>
          <span class="ts-row__state" data-test="tenant-agent-state">{{ s.online ? t('tenant_settings.online') : t('tenant_settings.offline') }}</span>
        </li>
      </ul>
    </template>
  </SettingsSection>

  <SettingsSection id="tenant-responders" :title="t('tenant_settings.responders_title')" data-test="tenant-settings-responders">
    <p class="muted ts-hint">{{ t('tenant_settings.responders_hint') }}</p>
    <ol v-if="responders.length" class="ts-list" data-test="tenant-responders-list">
      <li v-for="(id, i) in responders" :key="id" class="ts-row" data-test="tenant-responder-row" :data-agent="id">
        <span class="ts-row__n">{{ i + 1 }}.</span>
        <code class="ts-row__main">{{ id }}</code>
        <button
          type="button"
          class="icon-btn"
          :disabled="i === 0 || busy"
          :title="t('tenant_settings.move_up')"
          :aria-label="t('tenant_settings.move_up') + ' ' + id"
          data-test="tenant-responder-up"
          @click="responders = moveItem(responders, i, -1)"
        >
          <UiIcon name="chevron-up" :size="16" />
        </button>
        <button
          type="button"
          class="icon-btn"
          :disabled="i === responders.length - 1 || busy"
          :title="t('tenant_settings.move_down')"
          :aria-label="t('tenant_settings.move_down') + ' ' + id"
          data-test="tenant-responder-down"
          @click="responders = moveItem(responders, i, 1)"
        >
          <UiIcon name="chevron-down" :size="16" />
        </button>
        <button
          type="button"
          class="icon-btn"
          :disabled="busy"
          :title="t('tenant_settings.remove')"
          :aria-label="t('tenant_settings.remove') + ' ' + id"
          data-test="tenant-responder-remove"
          @click="responders = responders.filter((x) => x !== id)"
        >
          <UiIcon name="x" :size="16" />
        </button>
      </li>
    </ol>
    <p v-else class="muted" data-test="tenant-responders-empty">{{ t('tenant_settings.responders_empty') }}</p>
    <form class="ts-add" @submit.prevent="addResponder">
      <input
        v-model="candidate"
        type="text"
        list="tenant-responder-candidates"
        autocomplete="off"
        :placeholder="t('tenant_settings.responder_placeholder')"
        :aria-label="t('tenant_settings.responder_placeholder')"
        data-test="tenant-responder-input"
      >
      <datalist id="tenant-responder-candidates">
        <option v-for="id in candidates" :key="id" :value="id" />
      </datalist>
      <button type="submit" class="btn ghost" :disabled="busy || !candidate.trim()" data-test="tenant-responder-add">{{ t('tenant_settings.add') }}</button>
    </form>
    <div class="ts-actions">
      <button type="button" class="btn" :disabled="busy || !dirty" data-test="tenant-responders-save" @click="save">{{ t('tenant_settings.save') }}</button>
      <p v-if="notice" class="ts-notice" role="status" data-test="tenant-responders-notice">{{ notice }}</p>
      <p v-if="error" class="ts-error" role="alert" data-test="tenant-responders-error">{{ error }}</p>
    </div>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { moveItem, normalizeTenantSettings, tenantSettingsErrorKey, validResponderId } from '~/utils/tenant-settings.mjs'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()

type Seat = { id: string, box: string, online: boolean }
const seats = ref<Seat[]>([])
const responders = ref<string[]>([])
const saved = ref<string[]>([])
const max = ref(20)
const candidate = ref('')
const loading = ref(true)
const loadError = ref('')
const busy = ref(false)
const error = ref('')
const notice = ref('')

const dirty = computed(() => responders.value.join(',') !== saved.value.join(','))
const candidates = computed(() => [...new Set(seats.value.map((s) => s.id))].filter((id) => !responders.value.includes(id)))

async function load() {
  loading.value = true
  try {
    const [roster, settings] = await Promise.all([api.listRoster(), api.getTenantSettings()])
    const r = roster as { roster?: Record<string, string[]>, online?: string[] }
    const online = new Set(r.online || [])
    const out: Seat[] = []
    for (const [box, ids] of Object.entries(r.roster || {})) {
      if (box === 'box-wui') continue
      for (const id of ids) out.push({ id, box, online: online.has(`${id}@${box}`) })
    }
    out.sort((a, b) => Number(b.online) - Number(a.online) || a.id.localeCompare(b.id) || a.box.localeCompare(b.box))
    seats.value = out
    const s = normalizeTenantSettings(settings)
    responders.value = s.responders.slice()
    saved.value = s.responders.slice()
    max.value = s.maxResponders
    loadError.value = ''
  } catch (e) {
    loadError.value = t(tenantSettingsErrorKey(e))
  } finally {
    loading.value = false
  }
}

function addResponder() {
  const id = candidate.value.trim().toUpperCase()
  error.value = ''
  if (!validResponderId(id)) {
    error.value = t('tenant_settings.error.bad_responder')
    return
  }
  if (responders.value.length >= max.value) {
    error.value = t('tenant_settings.responders_full', { n: max.value })
    return
  }
  if (!responders.value.includes(id)) responders.value = [...responders.value, id]
  candidate.value = ''
}

async function save() {
  if (busy.value) return
  busy.value = true
  error.value = ''
  notice.value = ''
  try {
    const s = normalizeTenantSettings(await api.patchTenantSettings({ responders: responders.value }))
    responders.value = s.responders.slice()
    saved.value = s.responders.slice()
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
.ts-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.ts-row { display: flex; align-items: center; gap: 10px; min-height: 36px; padding: 2px 4px; min-width: 0; }
.ts-row__main { min-width: 0; overflow-wrap: anywhere; }
.ts-row__sub { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 0.8125rem; }
.ts-row__state { font-size: 0.8125rem; color: var(--color-muted); }
.ts-row__n { width: 2ch; color: var(--color-muted); }
.ts-dot { flex: none; width: 8px; height: 8px; border-radius: 50%; background: var(--color-muted); }
.ts-dot--on { background: var(--color-ok); }
.ts-hint { margin: 0 0 10px; }
.ts-add { display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
.ts-add input {
  flex: 1 1 160px;
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.ts-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-top: 12px; }
.ts-notice { margin: 0; color: var(--color-ok); }
.ts-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .ts-row { min-height: var(--tap, 44px); }
  .ts-row .icon-btn { width: var(--tap, 44px); height: var(--tap, 44px); }
  .ts-add input { min-height: var(--tap, 44px); }
  .ts-actions .btn, .ts-add .btn { min-height: var(--tap, 44px); }
}
</style>
