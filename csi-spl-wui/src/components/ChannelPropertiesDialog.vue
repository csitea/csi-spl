<!-- Properties for one channel (channels-v1 §7.4).
     Tabs, in order: About, People, Agents, Settings. Opens on People.
     UiDialog owns focus, Escape and the backdrop. -->
<template>
  <UiDialog :open="open" :title="t('sidebar.row_menu.properties')" size="md" @update:open="emit('update:open', $event)">
    <div ref="root" class="channel-properties" data-testid="channel-properties">
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
          <div class="people-add" data-testid="channel-people-picker">
            <Combobox
              as="div"
              class="people-add__combo"
              :model-value="chosenPerson"
              nullable
              :disabled="!canAdd || busy"
              @update:model-value="onChoosePerson"
            >
              <div class="people-add__control">
                <ComboboxInput
                  class="people-add__input"
                  data-testid="channel-people-search"
                  :aria-label="t('channels.properties.add_person')"
                  :placeholder="t('channels.properties.people_search')"
                  :display-value="personLabel"
                  autocomplete="off"
                  :disabled="!canAdd || busy"
                  @change="onPersonQuery"
                />
                <ComboboxButton
                  type="button"
                  class="people-add__chevron"
                  data-testid="channel-people-search-button"
                  :aria-label="t('channels.properties.add_person')"
                  :disabled="!canAdd || busy"
                >▾</ComboboxButton>
              </div>
              <ComboboxOptions class="people-add__options" data-testid="channel-people-options">
                <li
                  v-if="peopleChoices.length === 0"
                  class="people-add__empty muted"
                  data-testid="channel-invite-empty"
                >{{ personQuery.trim() ? t('channels.properties.people_no_matches') : t('channels.properties.invite_empty') }}</li>
                <ComboboxOption
                  v-for="id in peopleChoices"
                  :key="id"
                  :value="id"
                  as="template"
                  v-slot="{ active, selected }"
                >
                  <li
                    class="people-add__option"
                    :class="{ 'is-active': active, 'is-selected': selected }"
                    :data-testid="'channel-invite-pick-' + id"
                  >{{ id }}</li>
                </ComboboxOption>
              </ComboboxOptions>
            </Combobox>
            <button
              type="button"
              class="btn"
              data-testid="channel-people-add"
              :disabled="!canAdd || busy || !chosenPerson"
              @click="addChosen"
            >{{ t('channels.properties.add') }}</button>
          </div>
          <ul class="member-rows" data-testid="channel-invite-members">
            <li v-for="id in localMembers" :key="id">
              <span>{{ id }}</span>
              <button
                type="button"
                class="icon-btn"
                :data-testid="'channel-member-remove-' + id"
                :aria-label="t('channels.properties.remove_member', { id })"
                :disabled="busy || (!canAdd && id !== selfId)"
                @click="removePerson(id)"
              >
                <UiIcon name="minus" :size="16" />
              </button>
            </li>
          </ul>

          <div class="channel-properties__head">
            <span data-testid="channel-invite-agent">{{ t('channels.properties.agents_tab') }}</span>
            <button
              type="button"
              class="icon-btn"
              data-testid="channel-agent-add"
              :aria-label="t('channels.properties.add_agent')"
              :aria-expanded="addingAgents ? 'true' : 'false'"
              :disabled="!canAdd || busy"
              @click="addingAgents = !addingAgents"
            >
              <UiIcon name="plus" :size="16" />
            </button>
          </div>
          <p v-if="agentRows.length === 0" class="muted" data-testid="channel-people-agents-none">{{ t('channels.properties.agents_none') }}</p>
          <ul v-else class="member-rows" data-testid="channel-agents-list">
            <li v-for="row in agentRows" :key="row.id + '@' + row.box" :data-testid="'channel-agent-' + row.id">
              <span>{{ row.id }}</span>
              <span class="muted">{{ row.box }}</span>
              <button
                type="button"
                class="icon-btn"
                :data-testid="'channel-agent-remove-' + row.id"
                :aria-label="t('channels.properties.remove_agent', { id: row.id })"
                :disabled="!canAdd || busy"
                @click="removeAgent(row)"
              >
                <UiIcon name="minus" :size="16" />
              </button>
            </li>
          </ul>
          <template v-if="addingAgents && canAdd">
            <p v-if="agentCandidates.length === 0" class="muted" data-testid="channel-agent-invite-empty">{{ t('channels.properties.agents_invite_empty') }}</p>
            <ul v-else class="invite-candidates" data-testid="channel-agent-candidates">
              <li v-for="row in agentCandidates" :key="row.id + '@' + row.box">
                <button
                  type="button"
                  class="btn ghost"
                  :disabled="busy"
                  :data-testid="'channel-agent-invite-' + row.id"
                  @click="pickAgent(row)"
                >{{ row.id }} <span class="muted">{{ row.box }}</span></button>
              </li>
            </ul>
          </template>
          <p v-if="!canAdd" class="muted" data-testid="channel-invite-owner-only">{{ t('channels.properties.invite_owner_only') }}</p>
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
        <ul v-else class="invite-members" data-testid="channel-agents-readonly">
          <li v-for="row in agentRows" :key="row.id + '@' + row.box">
            <span>{{ row.id }}</span>
            <span class="muted">{{ row.box }}</span>
          </li>
        </ul>
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
  Combobox,
  ComboboxButton,
  ComboboxInput,
  ComboboxOption,
  ComboboxOptions,
} from '@headlessui/vue'
import {
  aboutChannelDescription,
  aboutChannelName,
  canAddChannelMember,
  canEditOpenInvite,
  channelAgentCandidates,
  channelAgentRows,
  channelInviteCandidates,
  filterPeopleContains,
  inviteErrorToken,
  rosterHumanIds,
  viewerHumanId,
} from '~/utils/spool-client.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { useLive } from '~/composables/useLive'
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
const live = useLive()
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
const addingAgents = ref(false)
const chosenPerson = ref<string | null>(null)
const personQuery = ref('')
const root = ref<HTMLElement | null>(null)
let ticket = 0
let sizedFor = 0

// The dialog otherwise hugs its content. The floor is twice that height,
// and never more than the backdrop leaves after its padding.
function applyDialogMinHeight() {
  const panel = root.value?.closest('.ui-dialog')
  if (!(panel instanceof HTMLElement)) return
  panel.style.minHeight = ''
  const natural = panel.getBoundingClientRect().height
  const backdrop = panel.parentElement
  const available = backdrop ? backdrop.clientHeight - 32 : 0
  const min = available > 0 ? Math.min(natural * 2, available) : natural * 2
  panel.style.minHeight = `${Math.round(min)}px`
}

watch(() => props.open, (isOpen) => {
  if (!isOpen) sizedFor = 0
})

watch(loaded, async (isLoaded) => {
  if (!props.open || !isLoaded || sizedFor === ticket) return
  sizedFor = ticket
  await nextTick()
  applyDialogMinHeight()
})

const nameText = computed(() => aboutChannelName({ name: props.name, channel_id: props.channelId }))
const descriptionText = computed(() => aboutChannelDescription({ description: props.description }))
const selfId = computed(() => viewerHumanId(access.me, live.identity.value, { mock: api.mock, rosterMe: roster.me?.id || '' }))
const effectiveCreatedBy = computed(() => createdByLive.value || props.createdBy)
const canEdit = computed(() => canEditOpenInvite({ selfId: selfId.value, createdBy: effectiveCreatedBy.value }))
const canAdd = computed(() => canAddChannelMember({
  selfId: selfId.value,
  createdBy: effectiveCreatedBy.value,
  membersOpenInvite: openInvite.value,
}))
const candidates = computed(() => channelInviteCandidates(rosterIds.value, localMembers.value))
const peopleChoices = computed(() => filterPeopleContains(candidates.value, personQuery.value))
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
  addingAgents.value = false
  chosenPerson.value = null
  personQuery.value = ''
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

function personLabel(id: unknown) {
  return typeof id === 'string' ? id : ''
}

function onPersonQuery(ev: Event) {
  const el = ev.target
  personQuery.value = el instanceof HTMLInputElement ? el.value : ''
}

function onChoosePerson(id: string | null) {
  chosenPerson.value = id
  personQuery.value = ''
}

async function addChosen() {
  const id = String(chosenPerson.value || '')
  if (!id || busy.value || !canAdd.value) return
  await pick(id)
  if (localMembers.value.includes(id)) {
    chosenPerson.value = null
    personQuery.value = ''
  }
}

async function removePerson(id: string) {
  if (busy.value || (!canAdd.value && id !== selfId.value)) return
  busy.value = true
  error.value = ''
  try {
    await withSessionRetry(api, () => api.removeChannelMember(props.channelId, id))
    localMembers.value = localMembers.value.filter((member) => member !== id)
  } catch (e) {
    error.value = inviteErrorToken(e)
  } finally {
    busy.value = false
  }
}

async function removeAgent(row: { id: string, box: string }) {
  if (busy.value || !canAdd.value) return
  busy.value = true
  error.value = ''
  try {
    await withSessionRetry(api, () => api.removeChannelAgent(props.channelId, row.id, row.box))
    agents.value = agents.value.filter((a) => !(a.id === row.id && a.box === row.box))
  } catch (e) {
    error.value = inviteErrorToken(e)
  } finally {
    busy.value = false
  }
}

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
.channel-properties__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-top: 8px;
  font-size: 13px;
  font-weight: 600;
}
.member-rows {
  display: flex;
  flex-direction: column;
  gap: 4px;
  margin: 0;
  padding: 0;
  list-style: none;
  min-width: 0;
}
.member-rows li {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.member-rows li span:first-child { min-width: 0; overflow-wrap: anywhere; }
.member-rows .icon-btn { margin-inline-start: auto; }
.channel-properties__head .icon-btn:disabled {
  opacity: 0.4;
  cursor: default;
}
.people-add {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  min-width: 0;
  max-width: 100%;
}
.people-add__combo {
  position: relative;
  flex: 1 1 auto;
  min-width: 0;
}
.people-add__control {
  display: flex;
  align-items: stretch;
  min-width: 0;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-composer);
}
.people-add__input {
  flex: 1 1 auto;
  min-width: 0;
  min-height: 40px;
  padding: 8px 10px;
  border: 0;
  background: transparent;
  color: var(--color-fg);
  font: inherit;
}
.people-add__chevron {
  flex: 0 0 auto;
  min-width: 40px;
  min-height: 40px;
  border: 0;
  border-inline-start: 1px solid var(--color-border);
  background: transparent;
  color: var(--color-muted);
  cursor: pointer;
}
.people-add__options {
  position: absolute;
  z-index: 2;
  inset-inline-start: 0;
  top: calc(100% + 4px);
  width: 100%;
  max-height: 16rem;
  margin: 0;
  padding: 4px 0;
  list-style: none;
  overflow: auto;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  box-shadow: 0 8px 24px rgb(0 0 0 / 0.28);
}
.people-add__option,
.people-add__empty {
  padding: 8px 12px;
  min-width: 0;
  overflow-wrap: anywhere;
}
.people-add__option { cursor: pointer; }
.people-add__option.is-active { background: var(--color-surface-hover); }
.people-add__option.is-selected { font-weight: 600; }
.people-add > .btn { flex: 0 0 auto; min-height: 40px; }
.people-add__input:disabled,
.people-add__chevron:disabled,
.people-add > .btn:disabled {
  opacity: 0.4;
  cursor: default;
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
