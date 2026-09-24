<!-- Properties for one channel (channels-v1 §7.4).
     Tabs, in order: About, People, Agents, Settings. Opens on People.
     UiDialog owns focus, Escape and the backdrop. -->
<template>
  <UiDialog :open="open" :title="t('sidebar.row_menu.properties')" size="md" @update:open="emit('update:open', $event)">
    <div class="channel-properties" data-testid="channel-properties">
      <div class="channel-properties__tabs" role="tablist">
        <button
          v-for="item in tabs"
          :key="item.id"
          type="button"
          role="tab"
          class="channel-properties__tab"
          :class="{ 'is-active': tab === item.id }"
          :aria-selected="tab === item.id"
          :aria-controls="'channel-properties-panel-' + item.id"
          :data-testid="'channel-properties-tab-' + item.id"
          @click="tab = item.id"
        >{{ t(item.label) }}</button>
      </div>
      <p v-if="error" class="invite-error" role="alert" data-testid="channel-invite-error">{{ error }}</p>

      <div
        v-show="tab === 'about'"
        id="channel-properties-panel-about"
        role="tabpanel"
        data-testid="channel-about"
      >
        <p class="channel-properties__row">
          <span>{{ t('channels.properties.about_name') }}</span>
          <span data-testid="channel-about-name">{{ nameText }}</span>
        </p>
        <p class="channel-properties__row">
          <span>{{ t('channels.properties.about_description') }}</span>
          <span v-if="descriptionText" data-testid="channel-about-description">{{ descriptionText }}</span>
          <span v-else class="muted" data-testid="channel-about-no-description">{{ t('channels.properties.about_no_description') }}</span>
        </p>
      </div>

      <div
        v-show="tab === 'people'"
        id="channel-properties-panel-people"
        role="tabpanel"
        data-testid="channel-people"
      >
        <p v-if="!loaded" class="muted">{{ t('common.loading') }}</p>
        <template v-else-if="!failedLoad">
          <ul v-if="localMembers.length" class="invite-members" data-testid="channel-invite-members">
            <li v-for="id in localMembers" :key="id">{{ id }}</li>
          </ul>
          <template v-if="canAdd">
            <p class="channel-properties__invite" data-testid="channel-invite-person">{{ t('channels.properties.invite_person') }}</p>
            <p v-if="candidates.length === 0" class="muted" data-testid="channel-invite-empty">{{ t('channels.properties.invite_empty') }}</p>
            <ul v-else class="invite-candidates" data-testid="channel-invite-candidates">
              <li v-for="(id, index) in candidates" :key="id">
                <span>{{ id }}</span>
                <button
                  type="button"
                  class="btn ghost"
                  :disabled="busy"
                  :data-autofocus="index === 0 ? '' : undefined"
                  :data-testid="'channel-invite-pick-' + id"
                  @click="pick(id)"
                >{{ t('channels.properties.invite') }}</button>
              </li>
            </ul>
          </template>
          <p v-else class="muted" data-testid="channel-invite-owner-only">{{ t('channels.properties.invite_owner_only') }}</p>
        </template>
      </div>

      <div
        v-show="tab === 'agents'"
        id="channel-properties-panel-agents"
        role="tabpanel"
        data-testid="channel-agents"
      >
        <p v-if="!loaded" class="muted">{{ t('common.loading') }}</p>
        <p v-else-if="agentRows.length === 0" class="muted" data-testid="channel-agents-none">{{ t('channels.properties.agents_none') }}</p>
        <ul v-else class="invite-members" data-testid="channel-agents-list">
          <li v-for="row in agentRows" :key="row.id + '@' + row.box" :data-testid="'channel-agent-' + row.id">
            <span>{{ row.id }}</span>
            <span class="muted">{{ row.box }}</span>
          </li>
        </ul>
        <template v-if="canAdd">
          <p class="channel-properties__invite" data-testid="channel-invite-agent">{{ t('channels.properties.invite_agent') }}</p>
          <p v-if="agentCandidates.length === 0" class="muted" data-testid="channel-agent-invite-empty">{{ t('channels.properties.agents_invite_empty') }}</p>
          <ul v-else class="invite-candidates" data-testid="channel-agent-candidates">
            <li v-for="row in agentCandidates" :key="row.id + '@' + row.box">
              <span>{{ row.id }}</span>
              <span class="muted">{{ row.box }}</span>
              <button
                type="button"
                class="btn ghost"
                :disabled="busy"
                :data-testid="'channel-agent-invite-' + row.id"
                @click="pickAgent(row)"
              >{{ t('channels.properties.invite') }}</button>
            </li>
          </ul>
        </template>
      </div>

      <div
        v-show="tab === 'settings'"
        id="channel-properties-panel-settings"
        role="tabpanel"
        data-testid="channel-settings"
      >
        <label class="channel-properties__check">
          <input
            type="checkbox"
            data-testid="channel-open-invite"
            :checked="openInvite"
            :disabled="!canEdit || busy"
            @change="onToggle"
          >
          <span>{{ t('channels.properties.everyone_can_invite') }}</span>
        </label>
      </div>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import {
  aboutChannelDescription,
  aboutChannelName,
  canAddChannelMember,
  canEditOpenInvite,
  channelAgentCandidates,
  channelAgentRows,
  channelInviteCandidates,
  inviteErrorToken,
  rosterHumanIds,
  signedInHuman,
} from '~/utils/spool-client.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'

const props = defineProps<{
  open: boolean
  channelId: string
  name: string
  description: string
  createdBy: string
}>()
const emit = defineEmits<{ 'update:open': [boolean] }>()

const tabs = [
  { id: 'about' as const, label: 'channels.properties.about_tab' },
  { id: 'people' as const, label: 'channels.properties.people_tab' },
  { id: 'agents' as const, label: 'channels.properties.agents_tab' },
  { id: 'settings' as const, label: 'channels.properties.settings_tab' },
]

const api = useSpoolApi()
const access = useAccessStore()
const roster = useRosterStore()
const { t } = useI18n({ useScope: 'global' })
const tab = ref<(typeof tabs)[number]['id']>('people')
const busy = ref(false)
const loaded = ref(false)
const failedLoad = ref(false)
const error = ref('')
const openInvite = ref(false)
const localMembers = ref<string[]>([])
const rosterIds = ref<string[]>([])
const rosterBag = ref<Record<string, string[]>>({})
const createdByLive = ref('')
const agents = ref<{ id: string, box: string }[]>([])
let ticket = 0

const nameText = computed(() => aboutChannelName({ name: props.name, channel_id: props.channelId }))
const descriptionText = computed(() => aboutChannelDescription({ description: props.description }))
const selfId = computed(() => signedInHuman(access.me, { mock: api.mock, rosterMe: roster.me?.id || '' }))
const effectiveCreatedBy = computed(() => createdByLive.value || props.createdBy)
const canEdit = computed(() => canEditOpenInvite({ selfId: selfId.value, createdBy: effectiveCreatedBy.value }))
const canAdd = computed(() => canAddChannelMember({
  selfId: selfId.value,
  createdBy: effectiveCreatedBy.value,
  membersOpenInvite: openInvite.value,
}))
const candidates = computed(() => channelInviteCandidates(rosterIds.value, localMembers.value))
const agentRows = computed(() => channelAgentRows(agents.value))
const agentCandidates = computed(() => channelAgentCandidates(rosterBag.value, agentRows.value))

function rosterOf(data: unknown): Record<string, string[]> | undefined {
  if (!data || typeof data !== 'object' || !('roster' in data)) return undefined
  const bag = (data as { roster?: unknown }).roster
  if (!bag || typeof bag !== 'object' || Array.isArray(bag)) return undefined
  return bag as Record<string, string[]>
}

watch(() => props.open, async (isOpen) => {
  if (!isOpen) return
  const my = ++ticket
  tab.value = 'people'
  error.value = ''
  loaded.value = false
  failedLoad.value = false
  busy.value = false
  openInvite.value = false
  localMembers.value = []
  rosterIds.value = []
  rosterBag.value = {}
  createdByLive.value = ''
  agents.value = []
  try {
    const [mem, ros] = await Promise.all([
      withSessionRetry(api, () => api.listChannelMembers(props.channelId)),
      withSessionRetry(api, () => api.listRoster()),
    ]) as [{ default?: boolean, members?: string[], members_open_invite?: boolean, created_by?: string, agents?: { id: string, box: string }[] }, unknown]
    if (my !== ticket) return
    if (mem.default) {
      error.value = 'channel_public'
      failedLoad.value = true
      return
    }
    localMembers.value = Array.isArray(mem.members) ? mem.members.map((id) => String(id)) : []
    openInvite.value = mem.members_open_invite === true
    createdByLive.value = String(mem.created_by || '')
    agents.value = Array.isArray(mem.agents) ? mem.agents : []
    const bag = rosterOf(ros) || {}
    rosterBag.value = bag
    rosterIds.value = rosterHumanIds(bag)
  } catch (e) {
    if (my !== ticket) return
    error.value = inviteErrorToken(e)
    failedLoad.value = true
  } finally {
    if (my === ticket) loaded.value = true
  }
})

async function pickAgent(row: { id: string, box: string }) {
  if (busy.value || !canAdd.value) return
  busy.value = true
  error.value = ''
  try {
    await withSessionRetry(api, () => api.addChannelAgent(props.channelId, row.id, row.box))
    if (!agents.value.some((a) => a.id === row.id && a.box === row.box)) {
      agents.value = [...agents.value, { id: row.id, box: row.box }]
    }
  } catch (e) {
    error.value = inviteErrorToken(e)
  } finally {
    busy.value = false
  }
}

async function pick(id: string) {
  if (busy.value || !canAdd.value) return
  busy.value = true
  error.value = ''
  try {
    await withSessionRetry(api, () => api.addChannelMember(props.channelId, id))
    if (!localMembers.value.includes(id)) localMembers.value = [...localMembers.value, id]
  } catch (e) {
    error.value = inviteErrorToken(e)
  } finally {
    busy.value = false
  }
}

async function onToggle(ev: Event) {
  const input = ev.target
  const next = input instanceof HTMLInputElement ? input.checked : !openInvite.value
  if (!canEdit.value || busy.value) return
  busy.value = true
  error.value = ''
  try {
    const saved = await withSessionRetry(api, () => api.setMembersOpenInvite(props.channelId, next)) as { members_open_invite?: boolean }
    openInvite.value = saved.members_open_invite === true
  } catch (e) {
    error.value = inviteErrorToken(e)
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.channel-properties {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 14px;
  min-width: 0;
  max-width: 100%;
}
.channel-properties__tabs {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  min-width: 0;
  max-width: 100%;
}
.channel-properties__tab {
  appearance: none;
  background: transparent;
  color: var(--color-muted);
  border: 0;
  border-bottom: 2px solid transparent;
  padding: 6px 8px;
  font: inherit;
  font-weight: 600;
  cursor: pointer;
}
.channel-properties__tab[aria-selected="true"] {
  color: var(--color-fg);
  border-bottom-color: var(--color-accent);
}
.channel-properties__row,
.channel-properties__check {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin: 0;
  min-width: 0;
  max-width: 100%;
  overflow-wrap: anywhere;
}
.invite-members,
.invite-candidates {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin: 0;
  padding: 0;
  list-style: none;
  min-width: 0;
  max-width: 100%;
}
.invite-members li { font-size: 13px; }
.channel-properties__invite {
  margin: 4px 0 0;
  font-size: 13px;
  font-weight: 600;
}
.invite-candidates li {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
  max-width: 100%;
}
.invite-candidates .btn {
  max-width: 100%;
  overflow-wrap: anywhere;
}
.invite-error {
  margin: 0;
  font-size: 12px;
  color: var(--color-danger);
  overflow-wrap: anywhere;
}
</style>
