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
          <!-- A default channel: every person is in it and nobody can be taken
               out, so its people are listed with no picker and no minus. Its
               agents are picked below like in any channel (owner decision
               2026-09-25): none until someone adds one. -->
          <template v-if="isDefault">
            <p class="muted" data-testid="channel-default-note">{{ t('channels.properties.default_everyone') }}</p>
            <ul class="member-rows" data-testid="channel-default-people">
              <li v-for="id in localMembers" :key="id" :data-testid="'channel-default-person-' + id">
                <SpoolAvatar :id="id" :box="HUMAN_BOX" :size="22" />
                <span class="member-rows__name">{{ id }}</span>
              </li>
            </ul>
          </template>
          <template v-else>
            <div class="invite-add" data-testid="channel-people-picker">
              <div class="invite-add__combo">
                <Combobox
                  as="div"
                  :model-value="chosenPerson"
                  nullable
                  :disabled="!canAdd || busy"
                  @update:model-value="onChoosePerson"
                >
                  <div class="invite-add__control">
                    <ComboboxInput
                      class="invite-add__input"
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
                      class="invite-add__chevron"
                      data-testid="channel-people-search-button"
                      :aria-label="t('channels.properties.add_person')"
                      :disabled="!canAdd || busy"
                    >▾</ComboboxButton>
                  </div>
                  <ComboboxOptions class="invite-add__options" data-testid="channel-people-options">
                    <li
                      v-if="peopleChoices.length === 0"
                      class="invite-add__empty muted"
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
                        class="invite-add__option"
                        :class="{ 'is-active': active, 'is-selected': selected }"
                        :data-testid="'channel-invite-pick-' + id"
                      ><SpoolAvatar :id="id" :box="HUMAN_BOX" :size="22" /> <span class="member-rows__name">{{ id }}</span></li>
                    </ComboboxOption>
                  </ComboboxOptions>
                </Combobox>
              </div>
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
                <SpoolAvatar :id="id" :box="HUMAN_BOX" :size="22" />
                <span class="member-rows__name">{{ id }}</span>
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

          </template>

          <div class="invite-add" data-testid="channel-agent-picker">
            <div class="invite-add__combo">
              <Combobox
                as="div"
                :model-value="chosenAgent"
                by="key"
                nullable
                :disabled="!canAdd || busy"
                @update:model-value="onChooseAgent"
              >
                <div class="invite-add__control">
                  <ComboboxInput
                    class="invite-add__input"
                    data-testid="channel-agent-search"
                    :aria-label="t('channels.properties.add_agent')"
                    :placeholder="t('channels.properties.agents_search')"
                    :display-value="agentLabel"
                    autocomplete="off"
                    :disabled="!canAdd || busy"
                    @change="onAgentQuery"
                  />
                  <ComboboxButton
                    type="button"
                    class="invite-add__chevron"
                    data-testid="channel-agent-search-button"
                    :aria-label="t('channels.properties.add_agent')"
                    :disabled="!canAdd || busy"
                  >▾</ComboboxButton>
                </div>
                <ComboboxOptions class="invite-add__options" data-testid="channel-agent-options">
                  <li
                    v-if="agentChoices.length === 0"
                    class="invite-add__empty muted"
                    data-testid="channel-agent-invite-empty"
                  >{{ agentQuery.trim() ? t('channels.properties.agents_no_matches') : t('channels.properties.agents_invite_empty') }}</li>
                  <ComboboxOption
                    v-for="row in agentChoices"
                    :key="row.key"
                    :value="row"
                    as="template"
                    v-slot="{ active, selected }"
                  >
                    <li
                      class="invite-add__option"
                      :class="{ 'is-active': active, 'is-selected': selected }"
                      :data-testid="'channel-agent-invite-' + row.id"
                    ><SpoolAvatar :id="row.id" :box="row.box" :size="22" /> <span class="member-rows__name">{{ row.id }}</span> <span class="muted">{{ row.box }}</span></li>
                  </ComboboxOption>
                </ComboboxOptions>
              </Combobox>
            </div>
            <button
              type="button"
              class="btn"
              data-testid="channel-agent-add"
              :disabled="!canAdd || busy || !chosenAgent"
              @click="addChosenAgent"
            >{{ t('channels.properties.add') }}</button>
          </div>
          <p v-if="agentRows.length === 0" class="muted" data-testid="channel-people-agents-none">{{ t('channels.properties.agents_none') }}</p>
          <ul v-else class="member-rows" data-testid="channel-agents-list">
            <li v-for="row in agentRows" :key="row.id + '@' + row.box" :data-testid="'channel-agent-' + row.id">
              <SpoolAvatar :id="row.id" :box="row.box" :size="22" />
              <span class="member-rows__name">{{ row.id }}</span>
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
          <p v-if="!canAdd && !isDefault" class="muted" data-testid="channel-invite-owner-only">{{ t('channels.properties.invite_owner_only') }}</p>
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
        <ul v-else class="member-rows" data-testid="channel-agents-readonly">
          <li v-for="row in agentRows" :key="row.id + '@' + row.box">
            <SpoolAvatar :id="row.id" :box="row.box" :size="22" />
            <span class="member-rows__name">{{ row.id }}</span>
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
  defaultChannelRows,
  filterAgentsContains,
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

// A person's avatar is keyed on the browser box, as in the feed and the sidebar.
const HUMAN_BOX = 'box-wui'

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
const isDefault = ref(false)
const error = ref('')
const openInvite = ref(false)
const localMembers = ref<string[]>([])
const rosterIds = ref<string[]>([])
const rosterBag = ref<Record<string, string[]>>({})
const createdByLive = ref('')
const agents = ref<{ id: string, box: string }[]>([])
const chosenPerson = ref<string | null>(null)
const personQuery = ref('')
const chosenAgent = ref<{ id: string, box: string, key: string } | null>(null)
const agentQuery = ref('')
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
const agentChoices = computed(() => filterAgentsContains(agentCandidates.value, agentQuery.value).map((row) => ({
  ...row,
  key: row.id + '@' + row.box,
})))

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
  isDefault.value = false
  busy.value = false
  openInvite.value = false
  localMembers.value = []
  rosterIds.value = []
  rosterBag.value = {}
  createdByLive.value = ''
  agents.value = []
  chosenPerson.value = null
  personQuery.value = ''
  chosenAgent.value = null
  agentQuery.value = ''
  try {
    const [mem, ros] = await Promise.all([
      withSessionRetry(api, () => api.listChannelMembers(props.channelId)),
      withSessionRetry(api, () => api.listRoster()),
    ]) as [{ default?: boolean, members?: string[], members_open_invite?: boolean, created_by?: string, agents?: { id: string, box: string }[] }, unknown]
    if (my !== ticket) return
    const bag = rosterOf(ros) || {}
    rosterBag.value = bag
    if (mem.default) {
      const everyone = defaultChannelRows(bag, mem.agents)
      isDefault.value = true
      localMembers.value = everyone.people
      agents.value = everyone.agents
      createdByLive.value = String(mem.created_by || 'hub')
      return
    }
    localMembers.value = Array.isArray(mem.members) ? mem.members.map((id) => String(id)) : []
    openInvite.value = mem.members_open_invite === true
    createdByLive.value = String(mem.created_by || '')
    agents.value = Array.isArray(mem.agents) ? mem.agents : []
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

function agentLabel(row: unknown) {
  if (!row || typeof row !== 'object') return ''
  const r = row as { id?: string, box?: string }
  if (!r.id) return ''
  return r.box ? `${r.id} ${r.box}` : r.id
}

function onAgentQuery(ev: Event) {
  const el = ev.target
  agentQuery.value = el instanceof HTMLInputElement ? el.value : ''
}

function onChooseAgent(row: { id: string, box: string, key: string } | null) {
  chosenAgent.value = row
  agentQuery.value = ''
}

async function addChosenAgent() {
  const row = chosenAgent.value
  if (!row || busy.value || !canAdd.value) return
  await pickAgent(row)
  if (agents.value.some((a) => a.id === row.id && a.box === row.box)) {
    chosenAgent.value = null
    agentQuery.value = ''
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
.member-rows__name { min-width: 0; overflow-wrap: anywhere; }
.member-rows .icon-btn { margin-inline-start: auto; }
.channel-properties__head .icon-btn:disabled {
  opacity: 0.4;
  cursor: default;
}
.invite-add {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  min-width: 0;
  max-width: 100%;
}
/* A plain div, not the Combobox: headlessui's Combobox renders a fragment,
   which never gets this component's scoped attribute, so a rule on it does not
   apply and the list anchored to the dialog backdrop - off the bottom of the
   page (CLE-3493). */
.invite-add__combo {
  position: relative;
  flex: 1 1 auto;
  min-width: 0;
}
.invite-add__control {
  display: flex;
  align-items: stretch;
  min-width: 0;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-composer);
}
.invite-add__input {
  flex: 1 1 auto;
  min-width: 0;
  min-height: 40px;
  padding: 8px 10px;
  border: 0;
  background: transparent;
  color: var(--color-fg);
  font: inherit;
}
.invite-add__chevron {
  flex: 0 0 auto;
  min-width: 40px;
  min-height: 40px;
  border: 0;
  border-inline-start: 1px solid var(--color-border);
  background: transparent;
  color: var(--color-muted);
  cursor: pointer;
}
.invite-add__options {
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
.invite-add__option,
.invite-add__empty {
  padding: 8px 12px;
  min-width: 0;
  overflow-wrap: anywhere;
}
.invite-add__option {
  display: flex;
  align-items: center;
  gap: 8px;
  cursor: pointer;
}
.invite-add__option.is-active { background: var(--color-surface-hover); }
.invite-add__option.is-selected { font-weight: 600; }
.invite-add > .btn { flex: 0 0 auto; min-height: 40px; }
.invite-add__input:disabled,
.invite-add__chevron:disabled,
.invite-add > .btn:disabled {
  opacity: 0.4;
  cursor: default;
}
.invite-error {
  margin: 0;
  font-size: 12px;
  color: var(--color-danger);
  overflow-wrap: anywhere;
}
</style>
