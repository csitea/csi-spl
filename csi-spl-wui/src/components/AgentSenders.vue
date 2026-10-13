<!-- SPL-1018 (spec 044 FR-OS-017, owner t1 dee4081d msg e9ec66fa): Workspace
     settings -> Agents -> who may message each agent. Per agent, a workspace
     admin picks the members who may DM it or @mention it; an agent with no
     list takes messages from every member, and a channel post that does not
     @mention it is never affected. The hub enforces it (403
     sender_not_allowed); this pane only edits it. tenant.settings, loaded on
     demand by tenant-settings/agents.vue. -->
<template>
  <SettingsSection id="tenant-agent-senders" :title="t('tenant_settings.senders.title')" data-test="tenant-agent-senders">
    <p class="muted ts-hint">{{ t('tenant_settings.senders.hint') }}</p>
    <p v-if="loading" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="loadError" class="ts-error" role="alert" data-test="tenant-senders-load-error">{{ loadError }}</p>
    <ul v-else class="ts-list" data-test="tenant-senders-list">
      <li v-for="id in agents" :key="id" class="as-item" data-test="tenant-sender-row" :data-agent="id">
        <div class="as-row">
          <code class="as-row__main">{{ id }}</code>
          <span class="as-row__state" data-test="tenant-sender-state">{{ summaryText(id) }}</span>
          <button
            v-if="editing !== id"
            type="button"
            class="btn ghost as-row__btn"
            data-test="tenant-sender-edit"
            @click="edit(id)"
          >{{ t('tenant_settings.senders.edit') }}</button>
        </div>
        <form v-if="editing === id" class="as-edit" data-test="tenant-sender-form" @submit.prevent="save(id)">
          <label class="as-opt">
            <input v-model="mode" type="radio" value="all" :name="'senders-' + id" data-test="tenant-sender-mode-all">
            {{ t('tenant_settings.senders.mode_all') }}
          </label>
          <label class="as-opt">
            <input v-model="mode" type="radio" value="list" :name="'senders-' + id" data-test="tenant-sender-mode-list">
            {{ t('tenant_settings.senders.mode_list') }}
          </label>
          <fieldset v-if="mode === 'list'" class="as-members" :disabled="busy">
            <legend class="sr-only">{{ t('tenant_settings.senders.mode_list') }}</legend>
            <label v-for="m in members" :key="m.humanId" class="as-opt" data-test="tenant-sender-member" :data-member="m.humanId">
              <input v-model="ticked" type="checkbox" :value="m.humanId">
              <span class="as-member__name">{{ m.displayName || m.email || m.humanId }}</span>
              <span class="muted as-member__id">{{ m.humanId }}</span>
            </label>
            <p v-if="!ticked.length" class="muted as-none" data-test="tenant-sender-none">{{ t('tenant_settings.senders.none_ticked') }}</p>
          </fieldset>
          <div class="ts-actions">
            <button type="submit" class="btn" :disabled="busy" data-test="tenant-sender-save">{{ t('tenant_settings.save') }}</button>
            <button type="button" class="btn ghost" :disabled="busy" data-test="tenant-sender-cancel" @click="editing = ''">{{ t('tenant_settings.senders.cancel') }}</button>
          </div>
        </form>
      </li>
    </ul>
    <p v-if="notice" class="ts-notice" role="status" data-test="tenant-senders-notice">{{ notice }}</p>
    <p v-if="error" class="ts-error" role="alert" data-test="tenant-senders-error">{{ error }}</p>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { normalizeDirectory } from '~/utils/tenant-users.mjs'
import { tenantSettingsErrorKey } from '~/utils/tenant-settings.mjs'
import { senderAgents, senderListsOf, senderSave, senderSummary } from '~/utils/sender-allow.mjs'

const props = defineProps<{ seats: { id: string }[] }>()

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

type Member = { humanId: string, displayName: string, email: string }
const lists = ref<Record<string, string[]>>({})
const members = ref<Member[]>([])
const loading = ref(true)
const loadError = ref('')
const busy = ref(false)
const error = ref('')
const notice = ref('')
const editing = ref('')
const mode = ref<'all' | 'list'>('all')
const ticked = ref<string[]>([])

const agents = computed(() => senderAgents(props.seats))

function summaryText(id: string) {
  const s = senderSummary(lists.value[id])
  if (s.state === 'all') return t('tenant_settings.senders.everyone')
  if (s.state === 'none') return t('tenant_settings.senders.nobody')
  return t('tenant_settings.senders.some', { n: s.n })
}

function edit(id: string) {
  const l = lists.value[id]
  editing.value = id
  mode.value = Array.isArray(l) ? 'list' : 'all'
  ticked.value = Array.isArray(l) ? l.slice() : []
  error.value = ''
  notice.value = ''
}

async function load() {
  loading.value = true
  try {
    const [l, dir] = await Promise.all([api.listAgentSenders(), api.listTenantUsers()])
    lists.value = senderListsOf(l)
    members.value = (normalizeDirectory(dir).members as Member[]).slice().sort((a, b) => (a.displayName || a.humanId).localeCompare(b.displayName || b.humanId))
    loadError.value = ''
  } catch (e) {
    loadError.value = t(tenantSettingsErrorKey(e))
  } finally {
    loading.value = false
  }
}

async function save(id: string) {
  if (busy.value) return
  const op = senderSave(lists.value[id], mode.value, ticked.value)
  if (!op) {
    editing.value = ''
    return
  }
  busy.value = true
  error.value = ''
  notice.value = ''
  try {
    const next = { ...lists.value }
    if (op.op === 'drop') {
      await api.dropAgentSenders(id)
      delete next[id]
    } else {
      next[id] = (await api.putAgentSenders(id, op.members)).members || op.members
    }
    lists.value = next
    editing.value = ''
    notice.value = t('tenant_settings.saved')
  } catch (e) {
    error.value = t(tenantSettingsErrorKey(e))
  } finally {
    busy.value = false
  }
}

onMounted(() => { void load() })
</script>

<style scoped>
.ts-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.ts-hint { margin: 0 0 10px; }
.as-row { display: flex; align-items: center; gap: 10px; min-height: 36px; padding: 2px 4px; min-width: 0; }
.as-row__main { min-width: 0; overflow-wrap: anywhere; }
.as-row__state { flex: 1 1 auto; min-width: 0; font-size: 0.8125rem; color: var(--color-muted); }
.as-row__btn { flex: none; padding: 2px 10px; font-size: 0.8125rem; }
.as-edit { display: flex; flex-direction: column; gap: 6px; padding: 8px 4px 12px 18px; }
.as-opt { display: flex; align-items: center; gap: 8px; min-width: 0; }
.as-members { border: 0; margin: 0; padding: 4px 0 0 22px; display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.as-member__name { min-width: 0; overflow-wrap: anywhere; }
.as-member__id { font-size: 0.8125rem; }
.as-none { margin: 0; font-size: 0.8125rem; }
.ts-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; margin-top: 6px; }
.ts-notice { margin: 8px 0 0; color: var(--color-ok); }
.ts-error { margin: 8px 0 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .as-row, .as-opt { min-height: var(--tap, 44px); }
  .ts-actions .btn, .as-row__btn { min-height: var(--tap, 44px); }
}
</style>
