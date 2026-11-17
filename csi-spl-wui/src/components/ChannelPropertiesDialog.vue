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
                <HumanName class="member-rows__name" :id="id" />
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
                        v-if="inactiveSet.has(id)"
                        class="invite-add__option"
                        :class="{ 'is-active': active, 'is-selected': selected }"
                        :data-testid="'channel-invite-pick-inactive-' + id"
                      ><SpoolAvatar :id="id" :box="HUMAN_BOX" :size="22" /> {{ t('channels.properties.invite_inactive', { label: personLabel(id) }) }}</li>
                      <li
                        v-else-if="inviteEmail(id)"
                        class="invite-add__option"
                        :class="{ 'is-active': active, 'is-selected': selected }"
                        data-testid="channel-invite-pick-email"
                      >{{ t('channels.properties.invite_email', { email: id }) }}</li>
                      <li
                        v-else
                        class="invite-add__option"
                        :class="{ 'is-active': active, 'is-selected': selected }"
                        :data-testid="'channel-invite-pick-' + id"
                      ><SpoolAvatar :id="id" :box="HUMAN_BOX" :size="22" /> <HumanName class="member-rows__name" :id="id" /></li>
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
                <HumanName class="member-rows__name" :id="id" />
                <button
                  type="button"
                  class="icon-btn"
                  :data-testid="'channel-member-remove-' + id"
                  :aria-label="t('channels.properties.remove_member', { id: personLabel(id) })"
                  :title="id"
                  :disabled="busy || (!canAdd && id !== selfId)"
                  @click="removePerson(id)"
                >
                  <UiIcon name="minus" :size="16" />
                </button>
              </li>
              <li v-for="email in localInvited" :key="email" :data-testid="'channel-invited-' + email">
                <SpoolAvatar :id="email" :box="HUMAN_BOX" :size="22" />
                <span class="member-rows__name">{{ personLabel(email) }}</span>
                <span class="muted" :title="t('channels.properties.invited_hint')">{{ t('channels.properties.invited') }}</span>
                <button
                  type="button"
                  class="icon-btn"
                  :data-testid="'channel-invited-remove-' + email"
                  :aria-label="t('channels.properties.remove_invited', { email: personLabel(email) })"
                  :disabled="busy || !canAdd"
                  @click="removePerson(email)"
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
              <span
                v-if="row.state"
                class="agent-state"
                :class="`agent-state--${row.state}`"
                :title="t(`channels.properties.agent_${row.state}_hint`)"
                :data-testid="`channel-agent-state-${row.id}`"
              >{{ t(`channels.properties.agent_${row.state}`) }}</span>
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
          <p v-if="fallback" class="fallback-line muted" data-testid="channel-fallback">
            <span class="fallback-line__label">{{ t('channels.properties.fallback_label') }}:</span>
            <span v-if="fallback.off" data-testid="channel-fallback-off">{{ t('channels.properties.fallback_off') }}</span>
            <template v-else-if="fallback.id">
              <span class="member-rows__name" data-testid="channel-fallback-id">{{ fallback.id }}</span>
              <span>{{ fallback.box }}</span>
              <span :data-testid="'channel-fallback-' + (fallback.active ? 'active' : 'standby')">{{ t(fallback.active ? 'channels.properties.fallback_active' : 'channels.properties.fallback_standby') }}</span>
            </template>
            <span v-else-if="!fallback.off" data-testid="channel-fallback-none">{{ t('channels.properties.fallback_none') }}</span>
            <span v-if="fallback.recent.count" data-testid="channel-fallback-recent">{{ t('channels.properties.fallback_recent', { count: fallback.recent.count, id: fallback.recent.id, at: fallback.recent.at }) }}</span>
          </p>
          <p v-if="!canAdd && !isDefault" class="muted" data-testid="channel-invite-owner-only">{{ t('channels.properties.invite_owner_only') }}</p>
        </template>
      </div>

      <div
        v-show="tab === 'agents'"
        id="channel-properties-panel-agents"
        role="tabpanel"
        data-testid="channel-agents"
      >
        <p v-if="loaded && !aiAgentsOn" class="muted" data-testid="channel-ai-agents-off-note">{{ t('channels.properties.ai_agents_off_note') }}</p>
        <p v-if="!loaded" class="muted">{{ t('common.loading') }}</p>
        <p v-else-if="agentRows.length === 0" class="muted" data-testid="channel-agents-none">{{ t('channels.properties.agents_none') }}</p>
        <ul v-else class="member-rows" data-testid="channel-agents-readonly">
          <li v-for="row in agentRows" :key="row.id + '@' + row.box">
            <SpoolAvatar :id="row.id" :box="row.box" :size="22" />
            <span class="member-rows__name">{{ row.id }}</span>
            <span class="muted">{{ row.box }}</span>
            <span
              v-if="row.state"
              class="agent-state"
              :class="`agent-state--${row.state}`"
              :title="t(`channels.properties.agent_${row.state}_hint`)"
              :data-testid="`channel-agent-state-${row.id}`"
            >{{ t(`channels.properties.agent_${row.state}`) }}</span>
          </li>
        </ul>
        <p v-if="fallback" class="fallback-line muted" data-testid="channel-fallback-ro">
          <span class="fallback-line__label">{{ t('channels.properties.fallback_label') }}:</span>
          <span v-if="fallback.off" data-testid="channel-fallback-off">{{ t('channels.properties.fallback_off') }}</span>
            <template v-else-if="fallback.id">
            <span class="member-rows__name" data-testid="channel-fallback-id">{{ fallback.id }}</span>
            <span>{{ fallback.box }}</span>
            <span :data-testid="'channel-fallback-' + (fallback.active ? 'active' : 'standby')">{{ t(fallback.active ? 'channels.properties.fallback_active' : 'channels.properties.fallback_standby') }}</span>
          </template>
          <span v-else-if="!fallback.off" data-testid="channel-fallback-none">{{ t('channels.properties.fallback_none') }}</span>
          <span v-if="fallback.recent.count" data-testid="channel-fallback-recent">{{ t('channels.properties.fallback_recent', { count: fallback.recent.count, id: fallback.recent.id, at: fallback.recent.at }) }}</span>
        </p>
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
        <!-- SPL-1684: the channel's AI agents switch. Off, agents do not read
             the channel; a DM or a mention still reaches one. -->
        <label class="channel-properties__check">
          <input
            type="checkbox"
            role="switch"
            data-testid="channel-ai-agents"
            :checked="aiAgentsOn"
            :aria-checked="aiAgentsOn"
            :disabled="!loaded || !canEditAIAgents || busy"
            @change="onToggleAIAgents"
          >
          <span>{{ t('channels.properties.ai_agents') }}</span>
        </label>
        <p class="muted" data-testid="channel-ai-agents-hint">{{ t(aiAgentsOn ? 'channels.properties.ai_agents_on_hint' : 'channels.properties.ai_agents_off_hint') }}</p>
        <p v-if="loaded && !canEditAIAgents" class="muted" data-testid="channel-ai-agents-edit-only">{{ t('channels.properties.ai_agents_edit_only') }}</p>
        <!-- spec 164 B6: the boxes this channel runs on. Any box of the
             workspace by default; a workspace admin (tenant.settings) may fix
             it to some of them. A default channel's save shows the hub's
             refusal (channel_default_unpinnable), never a silent save. -->
        <fieldset class="channel-boxes" data-testid="channel-boxes">
          <legend class="channel-boxes__label">{{ t('channels.properties.boxes_label') }}</legend>
          <p v-if="!boxes.loaded" class="muted">{{ t('common.loading') }}</p>
          <template v-else-if="!boxes.failed">
            <label class="channel-properties__check">
              <input
                type="radio"
                name="channel-boxes-mode"
                data-testid="channel-boxes-any"
                :checked="boxes.any"
                :disabled="!canEditBoxes || busy"
                @change="boxes.any = true"
              >
              <span>{{ t('channels.properties.boxes_any') }}</span>
            </label>
            <label class="channel-properties__check">
              <input
                type="radio"
                name="channel-boxes-mode"
                data-testid="channel-boxes-some"
                :checked="!boxes.any"
                :disabled="!canEditBoxes || busy"
                @change="boxes.any = false"
              >
              <span>{{ t('channels.properties.boxes_some') }}</span>
            </label>
            <div
              v-if="!boxes.any"
              class="channel-boxes__list"
              role="group"
              :aria-label="t('channels.properties.boxes_some')"
              data-testid="channel-boxes-list"
            >
              <label v-for="box in boxes.choices" :key="box" class="channel-properties__check">
                <input
                  v-model="boxes.ticked"
                  type="checkbox"
                  :value="box"
                  :data-testid="'channel-box-' + box"
                  :disabled="!canEditBoxes || busy"
                >
                <span>{{ box }}</span>
              </label>
              <p v-if="boxes.choices.length === 0" class="muted" data-testid="channel-boxes-none">{{ t('channels.properties.boxes_none') }}</p>
            </div>
            <button
              v-if="canEditBoxes"
              type="button"
              class="btn channel-boxes__save"
              data-testid="channel-boxes-save"
              :disabled="busy || !boxesDirty || (!boxes.any && boxes.ticked.length === 0)"
              @click="saveBoxes"
            >{{ t('channels.properties.boxes_save') }}</button>
            <p v-else class="muted" data-testid="channel-boxes-readonly">{{ t('channels.properties.boxes_readonly') }}</p>
          </template>
          <p class="muted" data-testid="channel-boxes-hint">{{ t('channels.properties.boxes_hint') }}</p>
          <p v-if="boxes.notice" class="channel-boxes__notice" role="status" data-testid="channel-boxes-saved">{{ t(boxes.notice) }}</p>
          <p v-if="boxes.error" class="invite-error" role="alert" data-testid="channel-boxes-error">{{ t(boxes.error) }}</p>
        </fieldset>
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
  channelFallbackLine,
  channelInviteCandidates,
  defaultChannelRows,
  filterAgentsContains,
  filterPeopleContains,
  inviteEmail,
  inviteErrorToken,
  viewerHumanId,
} from '~/utils/channel-members'
import { channelAgentsLive } from '~/utils/channel-agents-live'
import { rosterHumanIds } from '~/utils/spool-client.mjs'
import { invitedMembers, inviteeKeys } from '~/utils/invited-members-client.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { useLive } from '~/composables/useLive'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useChannelAgentPick } from '~/composables/useChannelAgentPick'
import { useChannelPersonPick } from '~/composables/useChannelPersonPick'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'
import { useHumanNames } from '~/composables/useHumanNames'
import { channelBoxChoices, channelBoxesLoadErrorKey, channelBoxPinsBody, channelBoxPinsErrorKey, normalizeChannelBoxPins, tenantChannelBoxPins, workspaceBoxIds } from '~/utils/tenant-settings.mjs'
import HumanName from '~/components/HumanName.vue'

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
const people = useHumanNames()
const { t } = useI18n({ useScope: 'global' })
const tab = ref<(typeof tabs)[number]['id']>('people')
const busy = ref(false)
const loaded = ref(false)
const failedLoad = ref(false)
const isDefault = ref(false)
const error = ref('')
const openInvite = ref(false)
// SPL-1684: the members answer carries ai_agents_off only when it is off.
const aiAgentsOn = ref(true)
const localMembers = ref<string[]>([])
// spec 025 section 11: addresses added before they joined the workspace
const localInvited = ref<string[]>([])
// spec 025 section 13: the workspace's inactive members (open invites), by
// key (the address, or the INV- id where it is masked), and every key's label
const inactiveKeys = ref<string[]>([])
const inviteLabels = ref<Record<string, string>>({})
const rosterIds = ref<string[]>([])
const rosterBag = ref<Record<string, string[]>>({})
const createdByLive = ref('')
const agents = ref<{ id: string, box: string, online?: boolean, seated?: boolean, state?: string }[]>([])
const chosenPerson = ref<string | null>(null)
const personQuery = ref('')
const chosenAgent = ref<{ id: string, box: string, key: string } | null>(null)
const agentQuery = ref('')
const root = ref<HTMLElement | null>(null)
let ticket = 0

// t1 1d657ae8: the dialog hugs its rows, centred by UiDialog's backdrop, and
// its body scrolls past the screen. A search list hanging below its input
// would be clipped by that body, so it is a fixed overlay pinned to the
// input: it opens down, or up when there is more room above, and never runs
// past the screen edge.
function placeOptions() {
  for (const list of root.value?.querySelectorAll<HTMLElement>('.invite-add__options') ?? []) {
    const control = list.closest('.invite-add__combo')?.querySelector('.invite-add__control')
    if (!control) continue
    const r = control.getBoundingClientRect()
    const below = window.innerHeight - r.bottom - 12
    const above = r.top - 12
    const down = below >= list.scrollHeight || below >= above
    list.style.left = `${Math.round(r.left)}px`
    list.style.width = `${Math.round(r.width)}px`
    list.style.maxHeight = `min(16rem, ${Math.max(0, Math.round(down ? below : above))}px)`
    list.style.top = down ? `${Math.round(r.bottom + 4)}px` : ''
    list.style.bottom = down ? '' : `${Math.round(window.innerHeight - r.top + 4)}px`
  }
}

watch(root, (el, _old, onCleanup) => {
  if (!el) return
  const seen = new MutationObserver(placeOptions)
  seen.observe(el, { childList: true, subtree: true })
  window.addEventListener('scroll', placeOptions, true)
  window.addEventListener('resize', placeOptions)
  onCleanup(() => {
    seen.disconnect()
    window.removeEventListener('scroll', placeOptions, true)
    window.removeEventListener('resize', placeOptions)
  })
}, { flush: 'post' })

const nameText = computed(() => aboutChannelName({ name: props.name, channel_id: props.channelId }))
const descriptionText = computed(() => aboutChannelDescription({ description: props.description }))
const selfId = computed(() => viewerHumanId(access.me, live.identity.value, { mock: api.mock, rosterMe: roster.me?.id || '' }))
const effectiveCreatedBy = computed(() => createdByLive.value || props.createdBy)
const canEdit = computed(() => canEditOpenInvite({ selfId: selfId.value, createdBy: effectiveCreatedBy.value }))
// SPL-1684: the channel's owner or a workspace admin; the hub checks again.
const canEditAIAgents = computed(() => canEdit.value || access.can('tenant.settings'))
const canAdd = computed(() => canAddChannelMember({
  selfId: selfId.value,
  createdBy: effectiveCreatedBy.value,
  membersOpenInvite: openInvite.value,
}))
const candidates = computed(() => [
  ...channelInviteCandidates(rosterIds.value, localMembers.value),
  ...inactiveKeys.value.filter((k) => !localInvited.value.includes(k)),
])
const inactiveSet = computed(() => new Set(inactiveKeys.value))
const peopleChoices = computed(() => {
  const found = filterPeopleContains(candidates.value, personQuery.value, { ...people.names.value, ...inviteLabels.value })
  // spec 025 section 11: a typed address is offered too, for a person who
  // has not joined the workspace yet (pending until they accept the invite)
  const email = inviteEmail(personQuery.value)
  return email && !localInvited.value.includes(email) && !found.includes(email) ? [...found, email] : found
})
// SPL-3717: each badge follows the roster store's live presence (refreshed on
// open below, then kept by the socket's presence frames), as the sidebar does.
const agentRows = computed(() => channelAgentsLive(channelAgentRows(agents.value), roster))
// SPL-997: who gets a post here when no member agent is online (FR-035).
const fallback = ref<ReturnType<typeof channelFallbackLine>>(null)
const agentCandidates = computed(() => channelAgentCandidates(rosterBag.value, agentRows.value))
const agentChoices = computed(() => filterAgentsContains(agentCandidates.value, agentQuery.value).map((row) => ({
  ...row,
  key: row.id + '@' + row.box,
})))
const { agentLabel, onAgentQuery, onChooseAgent, addChosenAgent, removeAgent } = useChannelAgentPick({
  api, channelId: () => props.channelId, busy, canAdd, error, agents, chosenAgent, agentQuery, fallback,
})
const { personLabel, onPersonQuery, onChoosePerson, addChosen, removePerson } = useChannelPersonPick({
  api, props, people, busy, canAdd, error, selfId, localMembers, localInvited, inviteLabels, chosenPerson, personQuery,
})

// spec 164 B6 (SPL-5560): the channel's box pins, read when the Settings
// tab is first shown. [] = any box of the workspace (the default). Declared
// before the immediate open watcher below, which resets it on mount.
const canEditBoxes = computed(() => access.can('tenant.settings'))
const boxes = reactive({ asked: false, loaded: false, failed: false, any: true, ticked: [] as string[], saved: [] as string[], choices: [] as string[], error: '', notice: '' })
const boxesDirty = computed(() => (boxes.any ? boxes.saved.length > 0 : [...boxes.ticked].sort().join() !== boxes.saved.join()))
function resetBoxes() {
  Object.assign(boxes, { asked: false, loaded: false, failed: false, any: true, ticked: [], saved: [], choices: [], error: '', notice: '' })
}
function showBoxPins(pins: string[]) {
  boxes.saved = pins
  boxes.ticked = [...pins]
  boxes.any = pins.length === 0
}

// immediate: SPL-1204 gates this dialog behind v-if in the sidebar, so it now
// mounts with open already true (channel_id and open are set in the same tick).
// Without immediate the false->true transition happens before this watcher
// exists, so the load never fires and People stays on "Loading…" (the invite
// regression). The guard below makes immediate a no-op when open is false.
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
  aiAgentsOn.value = true
  localMembers.value = []
  localInvited.value = []
  inactiveKeys.value = []
  inviteLabels.value = {}
  rosterIds.value = []
  rosterBag.value = {}
  createdByLive.value = ''
  agents.value = []
  fallback.value = null
  chosenPerson.value = null
  personQuery.value = ''
  chosenAgent.value = null
  agentQuery.value = ''
  resetBoxes()
  try {
    // SPL-3717: the roster is read into the shared store, so its presence is
    // fresh on open and the badges below stay live with the socket's frames.
    const [mem, inactive] = await Promise.all([
      withSessionRetry(api, () => api.listChannelMembers(props.channelId)),
      // spec 025 section 13: no list (an act-as session, an old hub) offers none
      withSessionRetry(api, () => invitedMembers(api)).catch(() => []),
      roster.refresh(),
    ]) as [{ default?: boolean, members?: string[], members_open_invite?: boolean, ai_agents_off?: boolean, created_by?: string, invited?: string[], invitees?: { id: string, label: string, masked: boolean }[], agents?: { id: string, box: string, online?: boolean, seated?: boolean }[], fallback?: unknown }, { id: string, label: string, masked: boolean }[], unknown]
    if (my !== ticket) return
    fallback.value = channelFallbackLine(mem.fallback)
    aiAgentsOn.value = mem.ai_agents_off !== true
    const bag = roster.roster
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
    showInvited(mem.invited, mem.invitees, inactive)
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
}, { immediate: true })

// spec 025 section 13: the channel's pending rows and the workspace's
// inactive members, each by its key, with one label map for both.
function showInvited(invited: string[] | undefined, rows: { id: string, label: string, masked: boolean }[] | undefined, inactive: { id: string, label: string, masked: boolean }[]) {
  const pending = inviteeKeys(rows)
  const open = inviteeKeys(inactive)
  localInvited.value = rows && rows.length ? pending.keys : (Array.isArray(invited) ? invited.map((e) => String(e)) : [])
  inactiveKeys.value = open.keys
  inviteLabels.value = { ...open.labels, ...pending.labels }
}

async function loadBoxes() {
  const my = ticket
  boxes.asked = true
  try {
    const [boxPins, all] = await Promise.all([readChannelBoxPins(), readWorkspacePins()])
    if (my !== ticket) return
    showBoxPins(boxPins)
    boxes.choices = channelBoxChoices(workspaceBoxIds(all), boxPins)
  } catch (e) {
    if (my !== ticket) return
    boxes.failed = true
    boxes.error = channelBoxesLoadErrorKey(e)
  } finally {
    if (my === ticket) boxes.loaded = true
  }
}
// The channel's pins. An admin who is not a member of a private channel gets
// 404 on its GET (channelDoor) yet may PUT (membersActor): read the admin list.
async function readChannelBoxPins(): Promise<string[]> {
  try {
    return normalizeChannelBoxPins(await withSessionRetry(api, () => api.getChannelBoxPins(props.channelId))).boxPins
  } catch (e) {
    if (!canEditBoxes.value || (e as { status?: number })?.status !== 404) throw e
    const pins = tenantChannelBoxPins(await withSessionRetry(api, () => api.listTenantChannels()), props.channelId)
    if (!pins) throw e
    return pins
  }
}
// GET /v1/pins takes the upload token; a 401 door redials for a fresh one once,
// as a file upload does (upload-fail.mjs).
async function readWorkspacePins() {
  try {
    return await api.listPins(await live.freshUploadToken())
  } catch (e) {
    if ((e as { status?: number })?.status !== 401) throw e
    return api.listPins(await live.freshUploadToken(true))
  }
}
watch(() => props.open && tab.value === 'settings', (shown) => {
  if (shown && !boxes.asked) void loadBoxes()
}, { immediate: true })
async function saveBoxes() {
  if (!canEditBoxes.value || busy.value || boxes.failed) return
  busy.value = true
  boxes.error = ''
  boxes.notice = ''
  try {
    const body = channelBoxPinsBody(boxes.any, boxes.ticked)
    const saved = await withSessionRetry(api, () => api.setChannelBoxPins(props.channelId, body.box_pins))
    showBoxPins(normalizeChannelBoxPins(saved).boxPins)
    boxes.notice = 'channels.properties.boxes_saved'
  } catch (e) {
    boxes.error = channelBoxPinsErrorKey(e)
  } finally {
    busy.value = false
  }
}

async function onToggleAIAgents(ev: Event) {
  const input = ev.target
  const next = input instanceof HTMLInputElement ? input.checked : !aiAgentsOn.value
  if (!canEditAIAgents.value || busy.value) return
  busy.value = true
  error.value = ''
  try {
    const saved = await withSessionRetry(api, () => api.setChannelAIAgents(props.channelId, next))
    aiAgentsOn.value = saved.ai_agents_off !== true
  } catch (e) {
    error.value = inviteErrorToken(e)
    if (input instanceof HTMLInputElement) input.checked = aiAgentsOn.value
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
/* SPL-987: can this agent hear the channel (hub view: box socket + roster). */
.agent-state {
  padding: 0 0.4rem;
  border: 1px solid currentColor;
  border-radius: var(--radius-pill);
  font-size: 0.75rem;
  line-height: 1.4;
  white-space: nowrap;
}
.agent-state--online { color: var(--color-ok); }
.agent-state--offline { color: var(--color-warn); }
.agent-state--unseated { color: var(--color-danger); }
/* spec 164 B6: the Boxes choice in the Settings tab. */
.channel-boxes {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin: 8px 0 0;
  padding: 0;
  border: 0;
  min-width: 0;
}
.channel-boxes__label { padding: 0; font-weight: 600; }
.channel-boxes__list {
  display: flex;
  flex-direction: column;
  gap: 4px;
  padding-inline-start: 1.5rem;
  min-width: 0;
}
.channel-boxes__save { align-self: flex-start; }
.channel-boxes__notice { margin: 0; color: var(--color-ok); }
/* SPL-997: the fallback responder line under the agent list. */
.fallback-line {
  display: flex;
  flex-wrap: wrap;
  gap: 0.25rem 0.5rem;
  align-items: baseline;
  margin-top: 0.5rem;
}
.fallback-line__label { font-weight: 600; }
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
   page. */
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
/* fixed, placed by placeOptions(): the dialog body would clip an absolute list */
.invite-add__options {
  position: fixed;
  z-index: 2;
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
/* SPL-993: touch screens - every control is a 44 px target (the dialog is
   full screen at <= 600 px, UiDialog), options too; on a phone the add
   button takes its own full-width line under the picker. */
@media (max-width: 820px) {
  .invite-add__input,
  .invite-add__chevron,
  .invite-add > .btn,
  .invite-add__option { min-height: var(--tap, 44px); }
  .invite-add__chevron { min-width: var(--tap, 44px); }
  .member-rows li { min-height: var(--tap, 44px); }
  .channel-boxes .channel-properties__check,
  .channel-boxes__save { min-height: var(--tap, 44px); align-items: center; }
  .member-rows .icon-btn,
  .channel-properties__head .icon-btn { width: var(--tap, 44px); height: var(--tap, 44px); }
}
@media (max-width: 600px) {
  .invite-add { flex-wrap: wrap; }
  .invite-add__combo { flex-basis: 100%; }
  .invite-add > .btn { flex: 1 1 100%; }
}
</style>
