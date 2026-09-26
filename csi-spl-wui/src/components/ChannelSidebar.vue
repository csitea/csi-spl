<template>
  <nav class="sidebar">
    <!-- Tenant drop box, above the direct-messages icon (specs/026 §6). One
         membership: one row, choosing it changes nothing. Several: every
         membership, and choosing one switches the session's tenant.
         CLE-34991: one slim row, a glyph instead of a visible caption; the
         caption is the select's name and hovering explains what a tenant is.
         The closed select is as wide as the widest option, then 3px, then
         the arrow, measured in the select's own font. -->
    <div ref="tenantSwitcherEl" class="tenant-switcher" data-testid="tenant-switcher" :title="tenantHintText">
      <UiIcon name="building" :size="14" class="tenant-switcher__icon" />
      <select
        ref="tenantSelectEl"
        class="tenant-switcher__select"
        data-testid="tenant-switcher-select"
        :value="tenantBox.selected"
        :aria-label="t('sidebar.tenant')"
        aria-describedby="tenant-switcher-hint"
        :aria-busy="switching ? 'true' : undefined"
        :style="tenantSelectStyle"
        @change="onTenantChange"
      >
        <option v-for="o in tenantBox.options" :key="o.id" :value="o.id">{{ o.label || t('sidebar.tenant') }}</option>
      </select>
      <svg
        ref="tenantArrowEl"
        class="tenant-switcher__arrow"
        data-testid="tenant-switcher-arrow"
        viewBox="0 0 8 6"
        aria-hidden="true"
        focusable="false"
        :style="tenantArrowStyle"
      >
        <path d="M0 0 H8 L4 6 Z" />
      </svg>
      <span id="tenant-switcher-hint" class="sr-only" data-testid="tenant-switcher-hint">{{ tenantHintText }}</span>
    </div>
    <p v-if="switchFailed" class="tenant-switcher__error" role="alert" data-testid="tenant-switch-error">{{ t('sidebar.tenant_switch_failed') }}</p>
    <div class="sidebar-main">
    <!-- Top to bottom: direct messages, channels, topics, flow.
         Icons only; each name lives on aria-label and title. -->
    <div
      class="sidebar-rail"
      role="tablist"
      aria-orientation="vertical"
      :aria-label="railLabel"
    >
      <button
        v-for="item in rail"
        :id="'sidebar-tab-' + item.id"
        :key="item.id"
        type="button"
        class="sidebar-tab"
        role="tab"
        :data-testid="'sidebar-tab-' + item.id"
        :aria-selected="tab === item.id ? 'true' : 'false'"
        :aria-controls="'sidebar-panel-' + item.id"
        :tabindex="tab === item.id ? 0 : -1"
        :aria-label="t(item.labelKey)"
        :title="t(item.labelKey)"
        @click="selectTab(item.id)"
        @keydown="onTabKey"
      >
        <UiIcon :name="item.icon" :size="20" />
        <span v-if="tabUnread(item.id)" class="sidebar-tab__pip" :data-testid="'sidebar-tab-' + item.id + '-unread'" aria-hidden="true" />
      </button>
    </div>
    <div class="sidebar-body">
      <div
        v-show="tab === 'dm'"
        id="sidebar-panel-dm"
        class="sidebar-panel"
        role="tabpanel"
        aria-labelledby="sidebar-tab-dm"
        data-testid="sidebar-panel-dm"
      >
    <h2 class="sidebar-help" tabindex="0" data-testid="sidebar-help-dm" aria-describedby="sidebar-help-dm-tip">
      {{ t('sidebar.direct_messages') }}
      <span id="sidebar-help-dm-tip" class="sidebar-help__tip" role="tooltip">{{ t('sidebar.help.direct_messages') }}</span>
    </h2>
    <div class="sidebar-scroll">
    <!-- CLE-3448: the reader's own row. A signed-in human is the one peer
         guaranteed to be online, and was the only one the pane never drew -
         so "am I connected?" had no answer here at all. It is not a link:
         there is no DM with yourself, and the row exists to show presence. -->
    <div
      v-if="roster.self"
      class="nav-item self-row"
      data-testid="people-self"
      :data-key="roster.self.label"
      aria-current="true"
      :title="t('auth.login.signed_in_as', { who: peerName(roster.self.id, roster.self.box) })"
    >
      <SpoolAvatar :id="roster.self.id" :box="roster.self.box" :size="22" />
      <span class="dot" :class="{ on: roster.self.online }" />
      <HumanName class="label" :id="roster.self.id" :box="roster.self.box" />
      <!-- `sidebar.you` carries its own brackets: a bracket hard-coded here
           lands on the wrong side of an RTL label (he), because the bidi
           algorithm resolves neutral punctuation from its surroundings. -->
      <span class="muted self-row__you">{{ t('sidebar.you') }}</span>
    </div>
    <div
      v-for="(p, peerIndex) in peers"
      :key="p.label"
      class="nav-row"
      :data-order="p.label"
      :class="{ 'nav-row--muted': mutedPeers[p.label], 'nav-row--blocked': blockedPeers[p.label], 'nav-row--pinned': pinnedPeers.includes(p.label), 'nav-row--drag': dragging('peers', p.label), 'nav-row--drop': dropping('peers', p.label, peerIndex), 'nav-row--drop-after': droppingAfter('peers', peerIndex, peers.length) }"
      @pointerdown="rowPointerDown($event, 'peers', p.label)"
      @contextmenu.prevent="openChannelMenu('dm:' + p.label)"
      @click.capture="swallowDragClick"
    >
    <NuxtLink
      class="nav-item"
      :class="{ active: channel.peer === p.label }"
      :data-key="p.label"
      :data-ts="channel.dmAt[p.label] || undefined"
      :data-online="p.online ? '1' : '0'"
      :to="localePath('/dm/' + encodeURIComponent(p.label))"
    >
      <SpoolAvatar :id="p.id" :box="p.box" :size="22" />
      <span class="dot" :class="{ on: p.online }" />
      <HumanName class="label" :id="p.id" :box="p.box" />
      <span v-if="notes.unread['dm:' + p.label]" class="badge-unread">{{ notes.previewUnread(notes.unread['dm:' + p.label]) }}</span>
    </NuxtLink>
    <SidebarRowMenu
      :menu-id="'dm:' + p.label"
      :name="peerName(p.id, p.box)"
      :href="localePath('/dm/' + encodeURIComponent(p.label))"
      :unread="!!notes.unread['dm:' + p.label]"

      :person="true"
      :admin="peerAdmin"
      :blocked="!!blockedPeers[p.label]"
      :muted="!!mutedPeers[p.label]"
      :pinned="pinnedPeers.includes(p.label)"
      @block="togglePeer('block', p.label)"
      @mute="togglePeer('mute', p.label)"
      @pin="togglePin(p.label)"
      @remove="removePeer(p)"
      @hide="hideFromList(p)"
      :open="rowMenu === 'dm:' + p.label"
      @toggle="toggleRowMenu('dm:' + p.label)"
      @close="closeRowMenu()"
      @open="navigateTo(localePath('/dm/' + encodeURIComponent(p.label)))"
      @mark-read="notes.markRead('dm:' + p.label)"
    />
    </div>
    </div>
      </div>
      <div
        v-show="tab === 'channels'"
        id="sidebar-panel-channels"
        class="sidebar-panel"
        role="tabpanel"
        aria-labelledby="sidebar-tab-channels"
        data-testid="sidebar-panel-channels"
      >
    <!-- CLE-00 (owner, 2026-09-22): the heading and the ONE control that adds
         a channel. A plain <button> next to the title, so Tab reaches it in
         document order and Enter / Space open the dialog - the old inline
         text field sat in the channel list itself, took two tab stops before
         anyone had decided to create anything, and had nowhere to put what
         the channel is FOR. -->
    <div class="sidebar-head">
      <h2 class="sidebar-help" tabindex="0" data-testid="sidebar-help-channels" aria-describedby="sidebar-help-channels-tip">
        {{ t('sidebar.channels') }}
        <span id="sidebar-help-channels-tip" class="sidebar-help__tip" role="tooltip">{{ t('sidebar.help.channels') }}</span>
      </h2>
      <button
        v-if="canCreate"
        type="button"
        class="icon-btn create-channel"
        data-testid="create-channel"
        :aria-label="t('sidebar.new_channel_label')"
        :title="t('sidebar.new_channel_label')"
        @click="openCreate"
      >
        <UiIcon name="plus" :size="18" />
      </button>
    </div>
    <div class="sidebar-scroll">
    <div
      v-for="(c, channelIndex) in channelRows"
      :key="c.channel_id"
      class="nav-row"
      :data-order="c.channel_id"
      :class="{ 'nav-row--muted': isChannelMuted(c.channel_id), 'nav-row--pinned': channelOrder.includes(c.channel_id), 'nav-row--drag': dragging('channels', c.channel_id), 'nav-row--drop': dropping('channels', c.channel_id, channelIndex), 'nav-row--drop-after': droppingAfter('channels', channelIndex, channelRows.length) }"
      @pointerdown="rowPointerDown($event, 'channels', c.channel_id)"
      @contextmenu.prevent="openChannelMenu('ch:' + c.channel_id)"
      @click.capture="swallowDragClick"
    >
    <NuxtLink
      class="nav-item"
      :class="{ active: channel.active === c.channel_id }"
      :data-key="c.channel_id"
      :data-ts="channelActivity(c, channel.liveAt) || undefined"
      :title="c.description || undefined"
      :to="localePath('/channel/' + c.channel_id)"
    >
      <span class="hash">#</span>
      <span class="label">{{ c.name }}</span>
      <span v-if="retentionLabel(c)" class="retention muted" :title="t('sidebar.retention_title', { retention: retentionLabel(c) })">{{ retentionLabel(c) }}</span>
      <span v-if="notes.mentions['ch:' + c.channel_id]" class="badge-mention" data-testid="mention-count">@{{ notes.previewUnread(notes.mentions['ch:' + c.channel_id]) }}</span>
      <span v-if="notes.unread['ch:' + c.channel_id]" class="badge-unread">{{ notes.previewUnread(notes.unread['ch:' + c.channel_id]) }}</span>
    </NuxtLink>
    <SidebarRowMenu
      :menu-id="'ch:' + c.channel_id"
      :name="c.name"
      :href="localePath('/channel/' + c.channel_id)"
      :unread="!!notes.unread['ch:' + c.channel_id]"
      :channel="true"
      :properties="showProperties(c.channel_id)"
      :muted="isChannelMuted(c.channel_id)"
      :open="rowMenu === 'ch:' + c.channel_id"
      @toggle="toggleRowMenu('ch:' + c.channel_id)"
      @close="closeRowMenu()"
      @open="navigateTo(localePath('/channel/' + c.channel_id))"
      @mark-read="notes.markRead('ch:' + c.channel_id)"
      @mute="toggleChannelMute(c.channel_id)"
      @properties="openProperties(c.channel_id)"
    />
    </div>
    </div>
    <!-- The new-channel dialog: title + description, one place, nothing in the
         list until it is created (013 FR-017 - UiDialog owns focus trap,
         Escape, backdrop and restored focus; this owns only the fields). -->
    <UiDialog v-model:open="createOpen" :title="t('sidebar.create_channel_title')" size="md">
      <form
        id="create-channel-form"
        class="create-channel-form"
        data-testid="create-channel-form"
        novalidate
        @submit.prevent="onCreate"
      >
        <label class="create-channel-form__field">
          <span>{{ t('sidebar.create_channel_name_label') }}</span>
          <input
            v-model="newChannel"
            type="text"
            maxlength="80"
            autocomplete="off"
            data-autofocus
            data-testid="create-channel-name"
            :placeholder="t('sidebar.new_channel_placeholder')"
            :disabled="creating"
          >
          <!-- the slug is what the URL and every @mention will say, so it is
               shown while it is still being typed, not discovered afterwards -->
          <small class="muted">{{ slug ? t('sidebar.create_channel_slug_hint', { slug }) : t('sidebar.create_channel_slug_rule') }}</small>
        </label>
        <label class="create-channel-form__field">
          <span>{{ t('sidebar.create_channel_description_label') }}</span>
          <textarea
            v-model="newDescription"
            rows="3"
            maxlength="500"
            data-testid="create-channel-description"
            :placeholder="t('sidebar.create_channel_description_placeholder')"
            :disabled="creating"
          />
          <small class="muted">{{ t('sidebar.create_channel_description_hint') }}</small>
        </label>
        <p v-if="createError" class="create-error" role="alert" data-testid="create-channel-error">{{ createError }}</p>
      </form>
      <template #footer>
        <div class="create-channel-form__actions">
          <button type="button" class="btn ghost" :disabled="creating" @click="createOpen = false">{{ t('common.cancel') }}</button>
          <button
            type="submit"
            form="create-channel-form"
            class="btn"
            data-testid="create-channel-submit"
            :disabled="creating || !slug"
          >{{ creating ? t('sidebar.create_channel_busy') : t('sidebar.create_channel_submit') }}</button>
        </div>
      </template>
    </UiDialog>
      </div>
      <div
        v-show="tab === 'topics'"
        id="sidebar-panel-topics"
        class="sidebar-panel"
        role="tabpanel"
        aria-labelledby="sidebar-tab-topics"
        data-testid="sidebar-panel-topics"
      >
        <h2>{{ t('nav.topics') }}</h2>
        <div class="sidebar-scroll">
        <p v-if="!viewer.loading && viewer.topics.length === 0" class="muted topic-empty">{{ t('pages.index.empty') }}</p>
        <div
          v-for="(row, topicIndex) in topicRows"
          :key="row.task_id"
          class="nav-row"
          :data-order="row.task_id"
          :class="{ 'nav-row--pinned': topicOrder.includes(row.task_id), 'nav-row--drag': dragging('topics', row.task_id), 'nav-row--drop': dropping('topics', row.task_id, topicIndex), 'nav-row--drop-after': droppingAfter('topics', topicIndex, topicRows.length) }"
          @pointerdown="rowPointerDown($event, 'topics', row.task_id)"
          @click.capture="swallowDragClick"
        >
        <a
          class="nav-item"
          :class="{ active: topicOpen === row.task_id }"
          :aria-current="topicOpen === row.task_id ? 'true' : undefined"
          :data-key="row.task_id"
          :data-ts="row.last_ts || undefined"
          :href="localePath('/t/' + row.task_id)"
          @click.exact.prevent="pane.open(row.task_id)"
        >
          <span class="label" :title="namedLine(row.participants.join(', '), people.names.value).title">{{ topicRowTitle(row.subject, peopleLabels(row.participants, people.names.value) || row.task_id) }}</span>
        </a>
        <SidebarRowMenu
          :menu-id="'th:' + row.task_id"
          :name="topicRowTitle(row.subject, peopleLabels(row.participants, people.names.value) || row.task_id)"
          :href="localePath('/t/' + row.task_id)"
          :unread="false"
          :open="rowMenu === 'th:' + row.task_id"
          @toggle="toggleRowMenu('th:' + row.task_id)"
          @close="closeRowMenu()"
          @open="pane.open(row.task_id)"
        />
        </div>
        </div>
      </div>
      <div
        v-show="tab === 'flow'"
        id="sidebar-panel-flow"
        class="sidebar-panel"
        role="tabpanel"
        aria-labelledby="sidebar-tab-flow"
        data-testid="sidebar-panel-flow"
      >
        <h2>{{ t('sidebar.flow') }}</h2>
        <div class="sidebar-scroll">
        <p v-if="flow.length === 0" class="muted topic-empty">{{ t('feed.empty') }}</p>
        <template v-for="row in flow" :key="row.key">
          <div v-if="row.kind === 'channel'" class="nav-row" :data-order="row.key" :class="{ 'nav-row--muted': isChannelMuted(row.id), 'nav-row--pinned': flowOrder.includes(row.key), 'nav-row--drag': dragging('flow', row.key), 'nav-row--drop': dropping('flow', row.key, flow.indexOf(row)), 'nav-row--drop-after': droppingAfter('flow', flow.indexOf(row), flow.length) }" @pointerdown="rowPointerDown($event, 'flow', row.key)" @click.capture="swallowDragClick" @contextmenu.prevent="openChannelMenu('flow:ch:' + row.id)">
          <NuxtLink
            class="nav-item"
            :class="{ active: channel.active === row.id }"
            :data-key="row.id"
            :data-kind="row.kind"
            :data-ts="row.at || undefined"
            :to="localePath('/channel/' + row.id)"
          >
            <span class="hash">#</span>
            <span class="label">{{ row.label }}</span>
            <span v-if="notes.unread['ch:' + row.id]" class="badge-unread">{{ notes.previewUnread(notes.unread['ch:' + row.id]) }}</span>
          </NuxtLink>
          <SidebarRowMenu
            :menu-id="'flow:ch:' + row.id"
            :name="row.label"
            :href="localePath('/channel/' + row.id)"
            :unread="!!notes.unread['ch:' + row.id]"
            :channel="true"
            :properties="showProperties(row.id)"
            :muted="isChannelMuted(row.id)"
            :open="rowMenu === 'flow:ch:' + row.id"
            @toggle="toggleRowMenu('flow:ch:' + row.id)"
            @close="closeRowMenu()"
            @open="navigateTo(localePath('/channel/' + row.id))"
            @mark-read="notes.markRead('ch:' + row.id)"
            @mute="toggleChannelMute(row.id)"
            @properties="openProperties(row.id)"
          />
          </div>
          <div v-else-if="row.kind === 'dm'" class="nav-row" :data-order="row.key" :class="{ 'nav-row--muted': mutedPeers[row.label], 'nav-row--blocked': blockedPeers[row.label], 'nav-row--pinned': flowOrder.includes(row.key), 'nav-row--drag': dragging('flow', row.key), 'nav-row--drop': dropping('flow', row.key, flow.indexOf(row)), 'nav-row--drop-after': droppingAfter('flow', flow.indexOf(row), flow.length) }" @pointerdown="rowPointerDown($event, 'flow', row.key)" @click.capture="swallowDragClick" @contextmenu.prevent="openChannelMenu('flow:dm:' + row.label)">
          <NuxtLink
            class="nav-item"
            :class="{ active: channel.peer === row.label }"
            :data-key="row.label"
            :data-kind="row.kind"
            :data-ts="row.at || undefined"
            :to="localePath('/dm/' + encodeURIComponent(row.label))"
          >
            <SpoolAvatar :id="row.id" :box="row.box" :size="22" />
            <span class="dot" :class="{ on: row.online }" />
            <HumanName class="label" :id="row.id" :box="row.box" />
            <span v-if="notes.unread['dm:' + row.label]" class="badge-unread">{{ notes.previewUnread(notes.unread['dm:' + row.label]) }}</span>
          </NuxtLink>
          <SidebarRowMenu
            :menu-id="'flow:dm:' + row.label"
            :name="peerName(row.id, row.box)"
            :href="localePath('/dm/' + encodeURIComponent(row.label))"
            :unread="!!notes.unread['dm:' + row.label]"

      :person="true"
      :admin="peerAdmin"
      :blocked="!!blockedPeers[row.label]"
      :muted="!!mutedPeers[row.label]"
      :pinned="flowOrder.includes(row.key)"
      @block="togglePeer('block', row.label)"
      @mute="togglePeer('mute', row.label)"
      @pin="toggleFlowPin(row)"
      @remove="removePeer(row)"
      @hide="hideFromList(row)"
            :open="rowMenu === 'flow:dm:' + row.label"
            @toggle="toggleRowMenu('flow:dm:' + row.label)"
            @close="closeRowMenu()"
            @open="navigateTo(localePath('/dm/' + encodeURIComponent(row.label)))"
            @mark-read="notes.markRead('dm:' + row.label)"
          />
          </div>
          <div v-else class="nav-row" :data-order="row.key" :class="{ 'nav-row--pinned': flowOrder.includes(row.key), 'nav-row--drag': dragging('flow', row.key), 'nav-row--drop': dropping('flow', row.key, flow.indexOf(row)), 'nav-row--drop-after': droppingAfter('flow', flow.indexOf(row), flow.length) }" @pointerdown="rowPointerDown($event, 'flow', row.key)" @click.capture="swallowDragClick">
          <a
            class="nav-item"
            :class="{ active: topicOpen === row.id }"
            :data-key="row.id"
            :data-kind="row.kind"
            :data-ts="row.at || undefined"
            :href="localePath('/t/' + row.id)"
            @click.exact.prevent="pane.open(row.id)"
          >
            <span class="label" :title="flowTopic(row).title">{{ flowTopic(row).text }}</span>
          </a>
          <SidebarRowMenu
            :menu-id="'flow:th:' + row.id"
            :name="flowTopic(row).text"
            :href="localePath('/t/' + row.id)"
            :unread="false"
            :open="rowMenu === 'flow:th:' + row.id"
            @toggle="toggleRowMenu('flow:th:' + row.id)"
            @close="closeRowMenu()"
            @open="pane.open(row.id)"
          />
          </div>
        </template>
        </div>
      </div>
      <!-- CLE-34990: the personal Event log; the list lives on /events -->
      <div
        v-show="tab === 'events'"
        id="sidebar-panel-events"
        class="sidebar-panel"
        role="tabpanel"
        aria-labelledby="sidebar-tab-events"
        data-testid="sidebar-panel-events"
      >
        <h2>{{ t('sidebar.events') }}</h2>
        <NuxtLink class="nav-row" data-testid="sidebar-events-open" :to="localePath('/events')">{{ t('events.title') }}</NuxtLink>
      </div>
      <!-- CLE-34969: the admin's Users (members.invite only); the list and
           the edit form live on /users -->
      <div
        v-if="usersVisible"
        v-show="tab === 'users'"
        id="sidebar-panel-users"
        class="sidebar-panel"
        role="tabpanel"
        aria-labelledby="sidebar-tab-users"
        data-testid="sidebar-panel-users"
      >
        <h2>{{ t('sidebar.users') }}</h2>
        <p class="muted sidebar-users-hint">{{ t('users.sidebar_hint') }}</p>
        <NuxtLink class="nav-row" data-testid="sidebar-users-open" :to="localePath('/users')">{{ t('users.title') }}</NuxtLink>
      </div>
    <div class="sidebar-foot">
      <div class="nav-item health" data-testid="connection-health" :title="t('sidebar.health_title', { state: stateLabel(live.state.value) })">
        <span class="health-dot" :class="health" />
        <span class="label muted">{{ t('sidebar.health.' + health) }}</span>
      </div>
      <NotificationCenter />
      <!-- identity, Sign in / Sign out: the top-right UserMenu (CLE-3402) -->
      <!-- CLE-3433: the semver plus the deployed commit, so "did my fix
           ship?" is answerable from the page instead of from build.json -->
      <p id="app-version" class="version-stamp" :title="versionTitle || undefined" data-test="app-version">{{ versionText }}</p>
    </div>
    </div>
    </div>
    <ChannelPropertiesDialog
      v-model:open="propertiesOpen"
      :channel-id="propertiesChannel.channel_id"
      :name="propertiesChannel.name"
      :description="propertiesChannel.description"
      :created-by="propertiesChannel.created_by"
    />
  </nav>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useRosterStore } from '~/stores/roster'
import { useViewerStore } from '~/stores/viewer'
import { useTopicStore } from '~/stores/topic'
import { useSessionStore } from '~/stores/session'
import { useAccessStore } from '~/stores/access'
import { isSignedOutVisitor } from '~/utils/shell-bootstrap.mjs'
import { loadMutedChannels, normalizeChannel, saveMutedChannels, toggleMutedChannel } from '~/utils/notify.mjs'
/* Async (CLE-34984): it carries @headlessui/vue + @tanstack/virtual-core
   (~17 KB gzip) that no first paint needs; it loads right after the shell. */
const ChannelPropertiesDialog = defineAsyncComponent(() => import('~/components/ChannelPropertiesDialog.vue'))
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useNotificationStore } from '~/stores/notification'
import { useLive } from '~/composables/useLive'
import HumanName from '~/components/HumanName.vue'
import { channelActivity, channelSlug, connectionHealth, namedLine, orderPeers, peopleLabels, retentionDays, shownPerson } from '~/utils/channel-feed.mjs'
import { feedbackChannelCopy } from '~/utils/feedback-channel.mjs'
import { buildStampText, buildStampTitle, readBuildStamp } from '~/utils/build-stamp.mjs'
import { useSidePane } from '~/composables/useSidePane'
import { EVENTS_TAB, flowRows, USERS_TAB, tabForPath } from '~/utils/sidebar-tabs.mjs'
import { usersEntryVisible } from '~/utils/tenant-users.mjs'
import { topicOpening } from '~/utils/view-api.mjs'
import { useHumanNames } from '~/composables/useHumanNames'
import { dropIndex, hidePeer, loadHiddenPeers, moveKey, peerHidden, pinRows, rowMenuAdmin, saveHiddenPeers } from '~/utils/sidebar-row-menu.mjs'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { measureControlText, TENANT_ARROW_GAP_PX, tenantClosedWidthPx, tenantDrawnLabels, tenantHint, tenantSwitchOptions, widestLabelWidth } from '~/utils/tenant-switcher.mjs'
import type { UiIconName } from '~/utils/uiIcons'

type SideTab = 'dm' | 'channels' | 'topics' | 'flow' | 'events' | 'users'
/* Direct messages, channels, topics, flow — top to bottom. A matching
   route follows the page; search and settings keep the reader's choice. */
const RAIL: { id: SideTab, icon: UiIconName, labelKey: string }[] = [
  { id: 'dm', icon: 'messages', labelKey: 'sidebar.direct_messages' },
  { id: 'channels', icon: 'hash', labelKey: 'sidebar.channels' },
  { id: 'topics', icon: 'list', labelKey: 'nav.topics' },
  { id: 'flow', icon: 'waves', labelKey: 'sidebar.flow' },
  /* CLE-34990: the personal Event log, directly after flow (owner, topic 4335f075). */
  { id: EVENTS_TAB, icon: 'history', labelKey: 'sidebar.events' },
]
const tab = ref<SideTab>('dm')
/* The topics list names each row from the opening of its first message. */
function topicRowTitle(subject: string, fallback: string) {
  const text = topicOpening(subject)
  return text ? t('topic.list_title', { text }) : fallback
}
function peerName(id: string, box?: string) {
  return shownPerson(id, box, people.names.value)
}
function flowTopic(row: { label?: string }) {
  return namedLine(String(row.label || ''), people.names.value)
}
const rowMenu = ref('')
function toggleRowMenu(id: string) {
  rowMenu.value = rowMenu.value === id ? '' : id
}
function closeRowMenu() { rowMenu.value = '' }
function openChannelMenu(id: string) { rowMenu.value = id }
/* The flow list stays up while a row from it is opened. Another icon clears it. */
const holdFlow = ref(false)
const route = useRoute()
watch(() => route.path, (path) => {
  rowMenu.value = ''
  if (holdFlow.value) return
  const next = tabForPath(path)
  if (next) tab.value = next
}, { immediate: true })
function onTabKey(e: KeyboardEvent) {
  const order = rail.value.map((item) => item.id)
  const i = order.indexOf(tab.value)
  let n = -1
  if (e.key === 'ArrowDown') n = (i + 1) % order.length
  else if (e.key === 'ArrowUp') n = (i - 1 + order.length) % order.length
  else if (e.key === 'Home') n = 0
  else if (e.key === 'End') n = order.length - 1
  else return
  e.preventDefault()
  const next = order[n]
  void selectTab(next)
  document.getElementById('sidebar-tab-' + next)?.focus()
}

const channel = useChannelStore()
const viewer = useViewerStore()
const pane = useLiveFeed('pane')
const topicStore = useTopicStore()
const roster = useRosterStore()
const session = useSessionStore()
const access = useAccessStore()
const api = useSpoolApi()
const signedOut = computed(() => isSignedOutVisitor(session.state, api.mock))
const notes = useNotificationStore()
const live = useLive()
const { t, te } = useI18n({ useScope: 'global' })
const tenantBox = computed(() => tenantSwitchOptions(session.claims, api.tenant))
const tenantHintText = computed(() => tenantHint(tenantBox.value, t))
const tenantSelectEl = ref<HTMLSelectElement | null>(null)
const tenantArrowEl = ref<SVGSVGElement | null>(null)
const tenantSwitcherEl = ref<HTMLElement | null>(null)
const tenantSelectBox = ref<{ width: number, padEnd: number } | null>(null)
const tenantArrowInsetEnd = ref('')
const tenantSelectStyle = computed(() => {
  const box = tenantSelectBox.value
  if (!box) return undefined
  return {
    width: box.width + 'px',
    paddingInlineEnd: box.padEnd + 'px',
    paddingInlineStart: '0px',
  }
})
const tenantArrowStyle = computed(() => (
  tenantArrowInsetEnd.value ? { insetInlineEnd: tenantArrowInsetEnd.value } : undefined
))
/* Widest option in the select's computed font, then 3px, then the arrow.
   Re-measured when the membership list changes, when the font-size setting
   changes (html data-font-size, spec 023), and when the rail's font kicks in. */
function applyTenantSelectWidth(retry = true) {
  const sel = tenantSelectEl.value
  const arrow = tenantArrowEl.value
  const wrap = tenantSwitcherEl.value
  const view = wrap?.ownerDocument?.defaultView
  if (!sel || !arrow || !wrap || !view) return
  const labels = tenantDrawnLabels(tenantBox.value.options, t('sidebar.tenant'))
  const text = widestLabelWidth(labels, (label) => measureControlText(sel, label))
  if (labels.some((label) => label.length > 0) && !(text > 0)) return
  const arrowPx = arrow.getBoundingClientRect().width
  if (!(arrowPx > 0)) {
    if (retry) view.requestAnimationFrame(() => applyTenantSelectWidth(false))
    return
  }
  const wrapCs = view.getComputedStyle(wrap)
  const pad = parseFloat(wrapCs.paddingInlineEnd || wrapCs.paddingRight) || 0
  const width = tenantClosedWidthPx(text, arrowPx, TENANT_ARROW_GAP_PX)
  if (!Number.isFinite(width)) return
  const padEnd = TENANT_ARROW_GAP_PX + arrowPx
  const prev = tenantSelectBox.value
  if (!prev || Math.abs(prev.width - width) > 0.01 || Math.abs(prev.padEnd - padEnd) > 0.01) {
    tenantSelectBox.value = { width, padEnd }
  }
  const inset = pad + 'px'
  if (tenantArrowInsetEnd.value !== inset) tenantArrowInsetEnd.value = inset
}
watch(
  () => tenantDrawnLabels(tenantBox.value.options, t('sidebar.tenant')).join('\n'),
  async () => {
    await nextTick()
    applyTenantSelectWidth()
  },
)
let tenantWidthMq: MediaQueryList | null = null
let tenantFontObs: MutationObserver | null = null
function onTenantWidthViewport() { applyTenantSelectWidth() }
onMounted(() => {
  applyTenantSelectWidth()
  const doc = tenantSwitcherEl.value?.ownerDocument
  const view = doc?.defaultView
  if (doc?.documentElement && typeof MutationObserver === 'function') {
    tenantFontObs = new MutationObserver(() => applyTenantSelectWidth())
    tenantFontObs.observe(doc.documentElement, { attributes: true, attributeFilter: ['data-font-size'] })
  }
  if (!view) return
  tenantWidthMq = view.matchMedia('(max-width: 800px)')
  tenantWidthMq.addEventListener('change', onTenantWidthViewport)
})
onBeforeUnmount(() => {
  tenantFontObs?.disconnect()
  tenantWidthMq?.removeEventListener('change', onTenantWidthViewport)
})
const authClient = useAuthClient()
const switching = ref(false)
const switchFailed = ref(false)
/* specs/026 §6: a member of several tenants switches here. The hub re-issues
   the session cookie; a full load then reads every feed of the new tenant
   (no store keeps the old tenant's rows). A refusal keeps the old tenant. */
async function onTenantChange(ev: Event) {
  const el = ev.target
  if (!(el instanceof HTMLSelectElement)) return
  const want = el.value
  const box = tenantBox.value
  if (!box.canSwitch || api.mock || switching.value || !want || want === box.selected) {
    el.value = box.selected
    return
  }
  switching.value = true
  switchFailed.value = false
  const out = await authClient.switchTenant(want)
  if (out.ok) {
    window.location.assign(localePath('/'))
    return
  }
  switching.value = false
  switchFailed.value = true
  el.value = box.selected
}
const localePath = useLocalePath()
/* CLE-34969: Users after flow, only when the hub lists members.invite. */
const usersVisible = computed(() => usersEntryVisible(access.me, { mock: api.mock }))
const rail = computed(() => (usersVisible.value
  ? [...RAIL, { id: USERS_TAB as SideTab, icon: 'users' as UiIconName, labelKey: 'sidebar.users' }]
  : RAIL))
const railLabel = computed(() => rail.value.map((item) => t(item.labelKey)).join(', '))
function sectionUnread(prefix: string) {
  return Object.entries(notes.unread).some(([k, n]) => k.startsWith(prefix) && Number(n) > 0)
}
const dmUnread = computed(() => sectionUnread('dm:'))
const channelUnread = computed(() => sectionUnread('ch:'))
const flowUnread = computed(() => dmUnread.value || channelUnread.value)
function tabUnread(id: SideTab) {
  if (id === 'dm') return dmUnread.value
  if (id === 'channels') return channelUnread.value
  if (id === 'flow') return flowUnread.value
  return false
}
const topicOpen = computed(() => {
  if (pane.taskId) return pane.taskId
  if (topicStore.open && topicStore.parentTaskId) return topicStore.parentTaskId
  const m = route.path.match(/\/t\/([^/]+)$/)
  return m ? decodeURIComponent(m[1]) : ''
})
/* A replies click opens the topic on the right and shows this list. The
   opened topic's title is the selected row, brought to the top. */
watch([topicOpen, tab, () => viewer.topics.length], async ([id, which]) => {
  if (which !== 'topics' || !id) return
  await nextTick()
  const panel = document.getElementById('sidebar-panel-topics')
  if (!panel) return
  const row = panel.querySelector(`[data-key="${CSS.escape(String(id))}"]`)
  const scroller = panel.querySelector<HTMLElement>('.sidebar-scroll')
  if (row && scroller) scrollRowToTop(scroller, row)
})
/* Topics opens the topic index. Flow stays on this page and mixes the
   three lists. Direct messages and channels only swap the sidebar. */
async function selectTab(next: SideTab) {
  holdFlow.value = next === 'flow'
  tab.value = next
  if (next === 'topics') {
    if (viewer.topics.length === 0) void viewer.loadTopics()
    if (tabForPath(route.path) !== 'topics') await navigateTo(localePath('/'))
    return
  }
  if (next === 'flow' && viewer.topics.length === 0) void viewer.loadTopics()
  if (next === USERS_TAB && tabForPath(route.path) !== USERS_TAB) await navigateTo(localePath('/users'))
  if (next === EVENTS_TAB && tabForPath(route.path) !== EVENTS_TAB) await navigateTo(localePath('/events'))
}
const sidePane = useSidePane()
watch(() => sidePane.requested.value, (req) => {
  if (!req) return
  /* The replies link shows the Topics list and stays on this page, so the
     topic that just opened remains the one the omnibox writes into. */
  if (req.stay) {
    holdFlow.value = false
    tab.value = req.id
    if ((req.id === 'topics' || req.id === 'flow') && viewer.topics.length === 0) void viewer.loadTopics()
    return
  }
  void selectTab(req.id)
})
watch(tab, (id) => {
  rowMenu.value = ''
  if (id !== USERS_TAB && id !== EVENTS_TAB) sidePane.setCurrent(id)
  if ((id === 'topics' || id === 'flow') && viewer.topics.length === 0) void viewer.loadTopics()
}, { immediate: true })
/** Socket state token (open, reconnecting, …) in words; an unknown token (a config error) shows as is. */
const stateLabel = (s: string) => (te('feed.live_state.' + s) ? t('feed.live_state.' + s) : s)
/** "7 d" for #alerts (spec 005 FR-012), in the active locale; '' for every other channel. */
function retentionLabel(c: { channel_id?: string, channel?: string, retention_days?: number }) {
  const n = retentionDays(c)
  return n ? t('sidebar.retention_days', { n }) : ''
}
const health = computed(() => connectionHealth(live.state.value))
/* CLE-3425: newest first here too - the peer we last exchanged a DM with on top */
const hiddenPeers = ref<Record<string, true>>({})
/* "Remove from list": this browser only, until a newer DM (sidebar-row-menu.mjs) */
const listHidden = ref<Record<string, string>>({})
const blockedPeers = ref<Record<string, true>>({})
const mutedPeers = ref<Record<string, true>>({})
const mutedChannels = ref<string[]>([])
const propertiesOpen = ref(false)
const propertiesChannel = ref({ channel_id: '', name: '', description: '', created_by: '' })
function isChannelMuted(id: string) {
  return mutedChannels.value.includes(normalizeChannel(id))
}
function toggleChannelMute(id: string) {
  mutedChannels.value = saveMutedChannels(toggleMutedChannel(mutedChannels.value, id))
}
// A default channel has Properties too: it lists everyone, read-only (CLE-3493).
function showProperties(_id: string) {
  return !isSignedOutVisitor(session.state, api.mock)
}
function openProperties(id: string) {
  const row = shownChannels.value.find((c) => c.channel_id === id)
  propertiesChannel.value = {
    channel_id: id,
    name: String(row?.name || id),
    description: String(row?.description || ''),
    created_by: String(row?.created_by || ''),
  }
  propertiesOpen.value = true
}
/* index 0 is the top. A drag replaces the whole list: that order is pinned,
   and a person who appears later sorts after it, in the usual activity order. */
const pinnedPeers = ref<string[]>([])
const channelOrder = ref<string[]>([])
const topicOrder = ref<string[]>([])
const flowOrder = ref<string[]>([])
const peerAdmin = computed(() => rowMenuAdmin(access.me))
/* A person's chosen display name; the id@box stays the key and the tooltip. */
const people = useHumanNames()
const peers = computed(() => pinRows(
  orderPeers(roster.peers, channel.dmAt)
    .filter((p) => !hiddenPeers.value[p.label] && !peerHidden(listHidden.value, p.label, channel.dmAt[p.label])),
  pinnedPeers.value,
))
/** #feedback shows its locale name and description; a stored description wins. */
const shownChannels = computed(() => channel.ordered.map((c) => {
  const copy = feedbackChannelCopy(c.channel_id, {
    name: t('channels.feedback.name'),
    description: t('channels.feedback.description'),
  }, c.description)
  if (!copy) return c
  return { ...c, name: copy.name, description: copy.description }
}))
const channelRows = computed(() => pinRows(
  shownChannels.value,
  channelOrder.value,
  (c) => String(c.channel_id || ''),
))
const topicRows = computed(() => pinRows(
  viewer.topics,
  topicOrder.value,
  (t) => String(t.task_id || ''),
))

function toggleOrder(order: string[], key: string) {
  return order.includes(key) ? order.filter((l) => l !== key) : [key, ...order.filter((l) => l !== key)]
}
function togglePin(label: string) {
  pinnedPeers.value = toggleOrder(pinnedPeers.value, label)
  flowOrder.value = toggleOrder(flowOrder.value, 'dm:' + label)
}
function toggleFlowPin(row: { key: string, kind: string, label: string }) {
  flowOrder.value = toggleOrder(flowOrder.value, row.key)
  if (row.kind === 'dm') pinnedPeers.value = toggleOrder(pinnedPeers.value, row.label)
}

function togglePeer(which: 'block' | 'mute', label: string) {
  const bag = which === 'block' ? blockedPeers : mutedPeers
  const next = { ...bag.value }
  if (next[label]) delete next[label]
  else next[label] = true
  bag.value = next
}

/* A human is a tenant member: DELETE /v1/members/{id}. A bot is not, so the
   row leaves this pane for the session and the hub membership is untouched. */
async function removePeer(p: { id?: string, label: string }) {
  const id = String(p.id || '')
  if (/^HUM-\d+$/.test(id) && !api.mock) {
    try {
      await api.removeMember(id)
    } catch {
      return
    }
    void roster.refresh()
  }
  hiddenPeers.value = { ...hiddenPeers.value, [p.label]: true }
  pinnedPeers.value = pinnedPeers.value.filter((l) => l !== p.label)
  flowOrder.value = flowOrder.value.filter((l) => l !== 'dm:' + p.label)
}
function hideFromList(p: { label: string }) {
  listHidden.value = saveHiddenPeers(hidePeer(listHidden.value, p.label, channel.dmAt[p.label] || ''))
  pinnedPeers.value = pinnedPeers.value.filter((l) => l !== p.label)
  flowOrder.value = flowOrder.value.filter((l) => l !== 'dm:' + p.label)
}
const flow = computed(() => pinRows(flowRows({
  channels: shownChannels.value,
  peers: peers.value,
  topics: viewer.topics,
  liveAt: channel.liveAt,
  dmAt: channel.dmAt,
}), flowOrder.value, (row) => String(row.key || '')))

type DragList = 'peers' | 'channels' | 'topics' | 'flow'
const drag = ref<{ list: DragList, key: string, overIndex: number, active: boolean } | null>(null)
let suppressDragClick = false
const dragPanel: Record<DragList, string> = {
  peers: 'sidebar-panel-dm',
  channels: 'sidebar-panel-channels',
  topics: 'sidebar-panel-topics',
  flow: 'sidebar-panel-flow',
}
function orderBag(list: DragList) {
  if (list === 'peers') return pinnedPeers
  if (list === 'channels') return channelOrder
  if (list === 'topics') return topicOrder
  return flowOrder
}
function dragging(list: DragList, key: string) {
  const d = drag.value
  return !!d && d.active && d.list === list && d.key === key
}
function dropping(list: DragList, key: string, index: number) {
  const d = drag.value
  if (!d || !d.active || d.list !== list || d.key === key) return false
  if (d.overIndex === index) return true
  return false
}
function droppingAfter(list: DragList, index: number, last: number) {
  const d = drag.value
  return !!d && d.active && d.list === list && d.overIndex >= last && index === last - 1
}
function rowPointerDown(e: PointerEvent, list: DragList, key: string) {
  if (e.button !== 0) return
  const target = e.target
  if (!(target instanceof Element) || target.closest('.sidebar-row-menu, button, input, textarea')) return
  const startY = e.clientY
  const pointerId = e.pointerId
  let active = false
  let overIndex = 0
  const panelId = dragPanel[list]
  const keysNow = () => {
    const panel = document.getElementById(panelId)
    return panel ? [...panel.querySelectorAll<HTMLElement>('.nav-row')].map((el) => el.dataset.order || '') : []
  }
  const move = (ev: PointerEvent) => {
    if (ev.pointerId !== pointerId) return
    if (!active && Math.abs(ev.clientY - startY) < 6) return
    active = true
    const panel = document.getElementById(panelId)
    const els = panel ? [...panel.querySelectorAll<HTMLElement>('.nav-row')] : []
    const rects = els.map((el) => {
      const r = el.getBoundingClientRect()
      return { top: r.top, bottom: r.bottom }
    })
    overIndex = dropIndex(rects, ev.clientY)
    drag.value = { list, key, overIndex, active: true }
  }
  const up = () => {
    window.removeEventListener('pointermove', move)
    window.removeEventListener('pointerup', up)
    if (active) {
      suppressDragClick = true
      const keys = keysNow()
      const from = keys.indexOf(key)
      if (from >= 0) orderBag(list).value = moveKey(keys, from, overIndex)
    }
    drag.value = null
  }
  window.addEventListener('pointermove', move)
  window.addEventListener('pointerup', up)
}
function swallowDragClick(e: MouseEvent) {
  if (!suppressDragClick) return
  suppressDragClick = false
  e.preventDefault()
  e.stopPropagation()
}
onMounted(() => {
  /* the route middleware has usually probed already; a second probe on every
     page load was one more session read for nothing (CLE-34984) */
  if (session.state === 'loading' || session.state === 'unknown') void session.probe()
  mutedChannels.value = loadMutedChannels()
  listHidden.value = loadHiddenPeers()
})
/* specs/025 FR-008: the role decides which actions are offered (the hub re-checks). */
watch(() => session.state, (st) => { if (st === 'in') access.load() }, { immediate: true })
const newChannel = ref('')
const newDescription = ref('')
const createOpen = ref(false)
const creating = ref(false)
const createError = ref('')
/* what the channel will actually be called in a URL and in an @mention */
const slug = computed(() => channelSlug(newChannel.value))
/* CLE-3433: `access.can` fails OPEN by design (the store only hides actions;
   the hub re-checks every write), which is right for a member whose /view/me
   read failed and wrong for a visitor who is not signed in at all - they were
   offered a control that can only answer 401. A settled signed-out probe is
   not a failed read. */
const canCreate = computed(() => !signedOut.value && access.can('channels.manage'))

function openCreate() {
  createError.value = ''
  createOpen.value = true
}

/* a dismissed dialog keeps nothing: the next + starts on an empty form */
watch(createOpen, (open) => {
  if (open) return
  newChannel.value = ''
  newDescription.value = ''
  createError.value = ''
})
const config = useRuntimeConfig()
const version = computed(() => String(config.public.appVersion || 'v0.1.0-dev'))
/* the deployed stamp, read once, client only; null in lde and on any failure */
const build = ref(null)
onMounted(async () => { build.value = await readBuildStamp() })
const versionText = computed(() => buildStampText(version.value, build.value))
const versionTitle = computed(() => buildStampTitle(build.value))

/** channels-v1 §5.1 errors, in words (409 channel_exists, 400 bad_channel). */
function createCopy(e: unknown) {
  const tok = (e && typeof e === 'object' && 'token' in e) ? String((e as { token?: unknown }).token || '') : ''
  if (tok === 'channel_exists') return t('sidebar.create_error.channel_exists')
  if (tok === 'bad_channel') return t('sidebar.create_error.bad_channel')
  if (tok === 'view_door') return t('sidebar.create_error.view_door')
  return e instanceof Error ? e.message : t('sidebar.create_error.fallback')
}

async function onCreate() {
  const name = newChannel.value.trim()
  if (!name || creating.value) return
  creating.value = true
  createError.value = ''
  try {
    const row = await channel.createChannel(name, newDescription.value.trim())
    /* close first: the dialog restores focus to the + it was opened from, and
       the watcher clears the form, so a failed create keeps what was typed */
    createOpen.value = false
    await navigateTo(localePath('/channel/' + row.channel_id))
  } catch (e) {
    createError.value = createCopy(e)
  } finally {
    creating.value = false
  }
}
</script>

<style scoped>
/* The strip owns the width (main.css, at most 5vw). These buttons fill
   that width and must not impose a 32px min that would push past the cap. */
.sidebar-tab {
  appearance: none;
  position: relative;
  display: grid;
  place-items: center;
  width: 100%;
  max-width: 100%;
  min-width: 0;
  aspect-ratio: 1;
  height: auto;
  margin: 0;
  padding: 0;
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-muted);
  cursor: pointer;
  line-height: 0;
  container-type: size;
}
.sidebar-tab:hover { background: var(--color-surface-hover); color: var(--color-fg); }
.sidebar-tab[aria-selected="true"] { color: var(--color-fg); }
.sidebar-tab :deep(svg) {
  width: min(22px, 70cqi);
  height: min(22px, 70cqi);
}
.sidebar-tab__pip {
  position: absolute;
  top: 2px;
  inset-inline-end: 2px;
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--color-accent);
  pointer-events: none;
}
.topic-empty { padding: 8px 16px; margin: 0; }
.retention { font-size: 11px; flex-shrink: 0; }
/* the reader's own row is a status line, not a destination: no pointer, no
   hover highlight, nothing that reads as "click me" (CLE-3448) */
.self-row { cursor: default; }
.self-row:hover { background: transparent; }
/* shrinks last, after the id: which row is yours matters more than the tail
   of a long label, and the 72px rail hides both (main.css max-width 800) */
.self-row__you { font-size: 12px; flex-shrink: 0; }
/* the 72px rail keeps avatar + dot and drops every word (main.css does the
   same to .label there); a bare "(you)" beside an avatar says nothing */
@media (max-width: 800px) {
  .self-row__you { display: none; }
}
/* the heading row: title on the left, the one + on the right */
.sidebar-head {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-shrink: 0;
  padding-inline-end: 10px;
  min-width: 0;
}
.sidebar-head h2 { flex: 1; min-width: 0; }
.create-channel-form {
  display: flex;
  flex-direction: column;
  gap: 14px;
  padding: 14px;
  min-width: 0;
}
.create-channel-form__field {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
}
.create-channel-form__field > span { font-size: 13px; font-weight: 600; }
.create-channel-form__field input,
.create-channel-form__field textarea {
  width: 100%;
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  background: var(--color-composer);
  border: 1px solid var(--color-border);
  color: var(--color-fg);
  border-radius: var(--radius-sm);
  padding: 8px;
  font: inherit;
}
.create-channel-form__field textarea { resize: vertical; }
.create-channel-form__field small { font-size: 11px; overflow-wrap: anywhere; }
.create-channel-form__actions {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
  flex-wrap: wrap;
}
.badge-mention {
  margin-left: auto;
  color: var(--color-danger);
  border: 1px solid var(--color-danger);
  border-radius: var(--radius-pill);
  font-size: 11px;
  padding: 0 6px;
  flex-shrink: 0;
}
.badge-mention + .badge-unread { margin-left: 4px; }
.create-error { margin: 0; font-size: 12px; color: var(--color-danger); overflow-wrap: anywhere; }
.health-dot {
  width: 8px; height: 8px; border-radius: 50%;
  background: var(--color-danger);
  flex-shrink: 0;
}
.health-dot.ok { background: var(--color-ok); }
.health-dot.warn { background: var(--color-muted); }

/* Each object keeps the link full width. The three-line menu sits on the
   trailing edge and must not cover the name. */
.nav-row {
  position: relative;
  min-width: 0;
}
.nav-row:focus-within { z-index: 4; }
.nav-row > .nav-item { padding-inline-end: 44px; }
.nav-row--muted { opacity: 0.55; }
.nav-row--blocked .label { text-decoration: line-through; }
.nav-row--pinned { box-shadow: inset 3px 0 0 var(--color-accent); }
.sidebar-help { position: relative; }
.sidebar-help__tip {
  position: absolute;
  z-index: 6;
  inset-inline-start: 0;
  top: calc(100% + 4px);
  width: 100%;
  max-width: 100%;
  box-sizing: border-box;
  margin: 0;
  padding: 8px 10px;
  background: var(--color-bg-2, var(--color-surface));
  border: 1px solid var(--color-border-strong, var(--color-border));
  border-radius: var(--radius-sm);
  color: var(--color-fg);
  font-size: 12px;
  font-weight: 400;
  letter-spacing: normal;
  text-transform: none;
  line-height: 1.4;
  white-space: normal;
  overflow-wrap: anywhere;
  box-shadow: 0 8px 24px rgb(0 0 0 / .28);
  opacity: 0;
  visibility: hidden;
  pointer-events: none;
}
.sidebar-help:hover .sidebar-help__tip,
.sidebar-help:focus .sidebar-help__tip,
.sidebar-help:focus-visible .sidebar-help__tip {
  opacity: 1;
  visibility: visible;
}
.nav-row { cursor: grab; }
.nav-row .nav-item { cursor: grab; }
.nav-row--drag { opacity: 0.45; }
.nav-row--drag,
.nav-row--drag .nav-item { cursor: grabbing; }
.nav-row--drop { box-shadow: inset 0 2px 0 var(--color-accent); }
.nav-row--drop-after { box-shadow: inset 0 -2px 0 var(--color-accent); }
@media (max-width: 800px) {
  .nav-row > .nav-item { padding-inline-end: 28px; }
}
/* Compact drop box (CLE-34991): one slim row, a glyph and a borderless
   select, no caption. The select's width is the widest option in its own
   font, plus 3px, plus the arrow (set from script, not a fixed px width).
   max-width keeps the row inside the sidebar. */
.tenant-switcher {
  position: relative;
  display: flex;
  align-items: center;
  gap: 4px;
  flex: 0 0 auto;
  align-self: flex-start;
  width: max-content;
  max-width: calc(100% - 12px);
  min-width: 0;
  box-sizing: border-box;
  margin: 4px 6px 0;
  padding: 0 4px;
  border-radius: var(--radius-sm);
  color: var(--color-muted);
  font-size: 0.75rem;
}
.tenant-switcher:hover { background: var(--color-surface); color: var(--color-fg); }
.tenant-switcher__icon { flex: 0 0 auto; }
.tenant-switcher__error {
  margin: 0.125rem 0.5rem 0;
  font-size: 0.6875rem;
  color: var(--color-danger);
}
.tenant-switcher__select {
  flex: 0 0 auto;
  box-sizing: border-box;
  min-height: 24px;
  height: 24px;
  padding: 0;
  background: transparent;
  color: var(--color-fg);
  border: 0;
  border-radius: var(--radius-sm);
  font: inherit;
  line-height: 1.2;
  text-align: start;
  appearance: none;
  -webkit-appearance: none;
}
.tenant-switcher__arrow {
  position: absolute;
  top: 50%;
  inset-inline-end: 4px;
  width: 0.65em;
  height: 0.5em;
  transform: translateY(-50%);
  pointer-events: none;
  fill: currentColor;
  color: var(--color-fg);
}
@media (max-width: 800px) {
  .tenant-switcher {
    max-width: calc(100% - 8px);
    margin: 4px 4px 0;
    padding: 0 2px;
    font-size: 0.6875rem;
  }
  .tenant-switcher__arrow { inset-inline-end: 2px; }
  .tenant-switcher__icon { display: none; }
}
</style>
