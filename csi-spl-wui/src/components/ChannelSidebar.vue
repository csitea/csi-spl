<template>
  <nav class="sidebar" :class="{ 'sidebar--rail': issuesRailOnly }">
    <!-- Tenant drop box, above the direct-messages icon (specs/026 §6). One
         membership: one row, choosing it changes nothing. Several: every
         membership, and choosing one switches the session's tenant.
         CLE-34991: one slim row, a glyph instead of a visible caption; the
         caption is the select's name and hovering explains what a tenant is.
         The closed select is as wide as the widest option, then 3px, then
         the arrow, measured in the select's own font.
         SPL-71: a drop box, not a dropdown menu - the name and the arrow sit
         in one bordered box, and pressing anywhere in it opens the list.
         Rows come in the hub's order (tenants.sort_order, rdb 0051). -->
    <div ref="tenantSwitcherEl" class="tenant-switcher" data-testid="tenant-switcher" :title="tenantHintText">
      <span class="tenant-switcher__icon"><UiIcon name="building" :size="14" /></span>
      <span
        class="tenant-switcher__field"
        data-testid="tenant-switcher-box"
        :style="{ gap: (TENANT_ARROW_GAP_PX - TENANT_TEXT_PAD_PX) + 'px' }"
        @mousedown="onTenantBoxPress"
      >
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
        class="tenant-switcher__arrow"
        data-testid="tenant-switcher-arrow"
        viewBox="0 0 8 6"
        aria-hidden="true"
        focusable="false"
      >
        <path d="M0 0 H8 L4 6 Z" />
      </svg>
      </span>
      <span id="tenant-switcher-hint" class="sr-only" data-testid="tenant-switcher-hint">{{ tenantHintText }}</span>
    </div>
    <p v-if="switchFailed" class="tenant-switcher__error" role="alert" data-testid="tenant-switch-error">{{ t('sidebar.tenant_switch_failed') }}</p>
    <div class="sidebar-main">
    <!-- The person's order (SPL-979, Settings → Behaviour → Left panel
         order; default: direct messages, channels, issues, topics, flow,
         event log), then Users for admins. Icons only; each name lives on
         aria-label and title. Dragging an icon reorders; a click navigates. -->
    <div
      ref="railEl"
      class="sidebar-rail"
      role="tablist"
      aria-orientation="vertical"
      :aria-label="railLabel"
      data-testid="sidebar-rail"
    >
      <button
        v-for="item in rail"
        :id="'sidebar-tab-' + item.id"
        :key="item.id"
        type="button"
        class="sidebar-tab"
        :class="{ 'sidebar-tab--dragging': railDrag.draggingId.value === item.id, 'sidebar-tab--movable': item.id !== USERS_TAB }"
        role="tab"
        :data-testid="'sidebar-tab-' + item.id"
        :data-reorder-id="item.id !== USERS_TAB ? item.id : undefined"
        :aria-selected="tab === item.id ? 'true' : 'false'"
        :aria-controls="'sidebar-panel-' + item.id"
        :tabindex="tab === item.id ? 0 : -1"
        :aria-label="t(item.labelKey)"
        :title="t(item.labelKey)"
        @pointerdown="item.id !== USERS_TAB && railDrag.down($event, item.id as RailId)"
        @click="selectTab(item.id)"
        @keydown="onTabKey"
      >
        <UiIcon :name="item.icon" :size="20" />
        <!-- SPL-989: the phone's level-1 strip names each section; hidden above 820 px -->
        <span class="sidebar-tab__label" aria-hidden="true">{{ t(item.labelKey) }}</span>
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
      :deletable="deletableChannel(c.channel_id)"
      :muted="isChannelMuted(c.channel_id)"
      :open="rowMenu === 'ch:' + c.channel_id"
      @toggle="toggleRowMenu('ch:' + c.channel_id)"
      @close="closeRowMenu()"
      @open="navigateTo(localePath('/channel/' + c.channel_id))"
      @mark-read="notes.markRead('ch:' + c.channel_id)"
      @mute="toggleChannelMute(c.channel_id)"
      @properties="openProperties(c.channel_id)"
      @delete="askDeleteChannel(c.channel_id)"
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
          <!-- SPL-985: @ opens the shared picker; Enter / Tab pick while it is open -->
          <span class="mention-anchor">
            <textarea
              ref="newDescriptionEl"
              v-model="newDescription"
              rows="3"
              maxlength="500"
              data-testid="create-channel-description"
              :placeholder="t('sidebar.create_channel_description_placeholder')"
              :disabled="creating"
              @input="descMp.sync"
              @click="descMp.sync"
              @keyup="descMp.sync"
              @blur="descMp.close"
              @keydown="descMp.onKeydown($event) || onSubmitKey($event, () => ($event.target as HTMLTextAreaElement).form?.requestSubmit())"
            />
            <MentionList :picker="descMp" />
          </span>
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
    <!-- SPL-72: Delete channel, its creator only, always behind this confirm -->
    <LazyChannelDeleteDialog
      v-if="deleteTarget.channel_id"
      v-model:open="deleteOpen"
      :channel-id="deleteTarget.channel_id"
      :name="deleteTarget.name"
      @deleted="onChannelDeleted"
    />
    <!-- SPL-986: a topic row's Delete, the card's own confirm (specs/041 §3.5) -->
    <LazyTopicDeleteDialog
      v-if="topicDeleteOpen && topicDeleteMsgId"
      v-model:open="topicDeleteOpen"
      :msg-id="topicDeleteMsgId"
      @deleted="onTopicRowDeleted"
    />
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
          @contextmenu.prevent="openTopicMenu('th:' + row.task_id, row.task_id)"
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
          :topic-archive="topicRowState(row.task_id)?.canArchive"
          :topic-delete="topicRowState(row.task_id)?.canDelete"
          :topic-state="topicRowState(row.task_id)?.state || ''"
          @toggle="toggleTopicMenu('th:' + row.task_id, row.task_id)"
          @close="closeRowMenu()"
          @open="pane.open(row.task_id)"
          @archive="archiveTopicRow(row.task_id)"
          @delete-topic="askDeleteTopic(row.task_id)"
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
            :deletable="deletableChannel(row.id)"
            :muted="isChannelMuted(row.id)"
            :open="rowMenu === 'flow:ch:' + row.id"
            @toggle="toggleRowMenu('flow:ch:' + row.id)"
            @close="closeRowMenu()"
            @open="navigateTo(localePath('/channel/' + row.id))"
            @mark-read="notes.markRead('ch:' + row.id)"
            @mute="toggleChannelMute(row.id)"
            @properties="openProperties(row.id)"
            @delete="askDeleteChannel(row.id)"
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
          <div v-else class="nav-row" :data-order="row.key" :class="{ 'nav-row--pinned': flowOrder.includes(row.key), 'nav-row--drag': dragging('flow', row.key), 'nav-row--drop': dropping('flow', row.key, flow.indexOf(row)), 'nav-row--drop-after': droppingAfter('flow', flow.indexOf(row), flow.length) }" @pointerdown="rowPointerDown($event, 'flow', row.key)" @click.capture="swallowDragClick" @contextmenu.prevent="openTopicMenu('flow:th:' + row.id, row.id)">
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
            :topic-archive="topicRowState(row.id)?.canArchive"
            :topic-delete="topicRowState(row.id)?.canDelete"
            :topic-state="topicRowState(row.id)?.state || ''"
            @toggle="toggleTopicMenu('flow:th:' + row.id, row.id)"
            @close="closeRowMenu()"
            @open="pane.open(row.id)"
            @archive="archiveTopicRow(row.id)"
            @delete-topic="askDeleteTopic(row.id)"
          />
          </div>
        </template>
        </div>
      </div>
      <!-- GRK-3519: Issues, third rail tab. The list is the middle pane. -->
      <div
        v-show="tab === 'issues' && issueEpics.length"
        id="sidebar-panel-issues"
        class="sidebar-panel"
        role="tabpanel"
        aria-labelledby="sidebar-tab-issues"
        data-testid="sidebar-panel-issues"
      >
        <!-- SPL-18: the level-1 rows, loaded only on this tab. No "All issues" row,
             so no ISSUES heading either (owner, topic 41e1ccfa): "Epics and
             features" is the panel's only section, at the top. -->
        <LazyIssueEpicsPanel v-if="tab === 'issues'" />
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
      <!-- owner, 2026-09-26: the connection dot, the alerts bell and the chime
           note on ONE row, icons only; the words are the hover text. -->
      <div class="foot-row">
        <div
          class="health"
          data-testid="connection-health"
          role="status"
          :title="t('sidebar.health_title', { state: stateLabel(live.state.value) })"
          :aria-label="t('sidebar.health.' + health)"
        >
          <span class="health-dot" :class="health" />
        </div>
        <NotificationCenter />
        <!-- The version sits on this row, just right of the note. Only the
             version is painted. Hover or click opens the commit, and it stays
             while the pointer is on it so the hash can be copied. -->
        <span
          class="vs-wrap"
          :class="{ 'is-open': vsOpen }"
          tabindex="0"
          data-test="app-version-wrap"
          :aria-label="versionText || undefined"
          :aria-expanded="vsOpen"
          @click="vsOpen = !vsOpen"
          @keydown.esc.stop="vsOpen = false; ($event.currentTarget as HTMLElement).blur()"
        >
          <p id="app-version" class="version-stamp" data-test="app-version"><span class="vs-ver">{{ versionLabel }}</span></p>
          <span v-if="buildCommit" class="vs-pop" role="tooltip" data-test="app-version-card">
            <span class="vs-pop__row">
              <span class="vs-pop__sha">{{ buildCommit }}</span>
              <button type="button" class="vs-pop__copy" data-test="app-version-copy" @click.stop="copyCommit">{{ vsCopied ? t('code.copied') : t('code.copy') }}</button>
            </span>
            <span v-if="buildMeta" class="vs-pop__meta">{{ buildMeta }}</span>
          </span>
        </span>
      </div>
      <!-- identity, Sign in / Sign out: the top-right UserMenu (CLE-3402) -->
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
import { useSubmitKey } from '~/composables/useSubmitKey'
import { useMentionPicker } from '~/composables/useMentionPicker'
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
import { buildStampText, readBuildStamp } from '~/utils/build-stamp.mjs'
import { useSidePane } from '~/composables/useSidePane'
import { ARCHIVE_TAB, EVENTS_TAB, ISSUES_TAB, flowRows, USERS_TAB, tabForPath } from '~/utils/sidebar-tabs.mjs'
import { RAIL_TABS, type RailId } from '~/utils/rail-order.mjs'
import { useRailOrder } from '~/composables/useRailOrder'
import { useDragReorder } from '~/composables/useDragReorder'
import { usersEntryVisible } from '~/utils/tenant-users.mjs'
import { topicOpening } from '~/utils/view-api.mjs'
import { useHumanNames } from '~/composables/useHumanNames'
import { useTopicRowActions } from '~/composables/useTopicRowActions'
import { canDeleteChannel, viewerHumanId } from '~/utils/spool-client.mjs'
import { dropIndex, hidePeer, loadHiddenPeers, moveKey, peerHidden, pinRows, rowMenuAdmin, saveHiddenPeers } from '~/utils/sidebar-row-menu.mjs'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { measureControlText, TENANT_ARROW_GAP_PX, TENANT_TEXT_PAD_PX, tenantDrawnLabels, tenantHint, tenantSwitchOptions, widestLabelWidth } from '~/utils/tenant-switcher.mjs'
import type { UiIconName } from '~/utils/uiIcons'

type SideTab = 'dm' | 'channels' | 'topics' | 'flow' | 'issues' | 'events' | 'archive' | 'users'
/* The six rail tabs (utils/rail-order.mjs RAIL_TABS) in the person's order
   (SPL-979). A matching route follows the page; search and settings keep the
   reader's choice. */
const railOrder = useRailOrder()
const railEl = ref<HTMLElement | null>(null)
const railDrag = useDragReorder<RailId>({
  order: () => railOrder.order.value,
  items: () => [...(railEl.value?.querySelectorAll<HTMLElement>('[data-reorder-id]') || [])],
  onDrop: (next) => { void railOrder.save(next) },
})
const RAIL_BY_ID = new Map(RAIL_TABS.map((item) => [item.id, item]))
const RAIL = computed(() => (railDrag.preview.value || railOrder.order.value)
  .map((id) => RAIL_BY_ID.get(id))
  .filter((item): item is (typeof RAIL_TABS)[number] => Boolean(item))
  .map((item) => ({ id: item.id as SideTab, icon: item.icon as UiIconName, labelKey: item.labelKey })))
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
/* SPL-986: a topic row's menu also offers Archive / Delete once the hub said
   the viewer may (composables/useTopicRowActions.ts). */
const {
  stateOf: topicRowState,
  resolve: resolveTopicRow,
  archive: archiveTopicRow,
  deleteOpen: topicDeleteOpen,
  deleteMsgId: topicDeleteMsgId,
  askDelete: askDeleteTopic,
  onDeleted: onTopicRowDeleted,
} = useTopicRowActions()
function openTopicMenu(key: string, taskId: string) {
  rowMenu.value = key
  void resolveTopicRow(taskId)
}
function toggleTopicMenu(key: string, taskId: string) {
  toggleRowMenu(key)
  if (rowMenu.value === key) void resolveTopicRow(taskId)
}
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
/* SPL-976: the description's submit key creates the channel, as the button does */
const { onKeydown: onSubmitKey } = useSubmitKey()
const tenantBox = computed(() => tenantSwitchOptions(session.claims, api.tenant))
const tenantHintText = computed(() => tenantHint(tenantBox.value, t))
const tenantSelectEl = ref<HTMLSelectElement | null>(null)
const tenantSwitcherEl = ref<HTMLElement | null>(null)
const tenantTextPx = ref(0)
const tenantSelectStyle = computed(() => {
  const text = tenantTextPx.value
  if (!(text > 0)) return undefined
  return { width: (text + 2 * TENANT_TEXT_PAD_PX) + 'px', paddingInline: TENANT_TEXT_PAD_PX + 'px' }
})
/* The select is only as wide as the widest option in its own font. The arrow
   is the next flex item, TENANT_ARROW_GAP_PX after that edge, so a clamped
   rail cannot slide the arrow back over the name. Re-measured when the list,
   the font-size setting (html data-font-size), or the rail font changes. */
function applyTenantSelectWidth() {
  const sel = tenantSelectEl.value
  if (!sel) return
  const labels = tenantDrawnLabels(tenantBox.value.options, t('sidebar.tenant'))
  const text = widestLabelWidth(labels, (label) => measureControlText(sel, label))
  if (labels.some((label) => label.length > 0) && !(text > 0)) return
  if (Math.abs(tenantTextPx.value - text) > 0.01) tenantTextPx.value = text
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
  tenantWidthMq = view.matchMedia('(max-width: 820px)')
  tenantWidthMq.addEventListener('change', onTenantWidthViewport)
})
onBeforeUnmount(() => {
  tenantFontObs?.disconnect()
  tenantWidthMq?.removeEventListener('change', onTenantWidthViewport)
})
/* SPL-71: the arrow and the box's padding are part of the drop box, so a
   press there opens the list as a press on the name does. */
function onTenantBoxPress(ev: MouseEvent) {
  const sel = tenantSelectEl.value
  if (!sel || ev.button !== 0 || ev.target === sel || sel.contains(ev.target as Node)) return
  ev.preventDefault()
  sel.focus()
  try {
    (sel as HTMLSelectElement & { showPicker?: () => void }).showPicker?.()
  } catch { /* no picker without a user gesture: focus is enough */ }
}
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
  /* SPL-959: with tenant hosts on, a tenant IS its host: go there, same path. */
  const hostUrl = await tenantHostUrl(want, window.location.pathname)
  if (hostUrl) {
    window.location.assign(hostUrl)
    return
  }
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
/* No "All issues" row. With no epic rows the panel is empty, so the
   sidebar keeps the icon rail and the issue list takes the width. */
const issueEpics = useState<Array<{ key: string }>>('issue-epics', () => [])
const issuesRailOnly = computed(() => tab.value === 'issues' && issueEpics.value.length === 0)
/* CLE-34969: Users after flow, only when the hub lists members.invite. */
const usersVisible = computed(() => usersEntryVisible(access.me, { mock: api.mock }))
const rail = computed(() => (usersVisible.value
  ? [...RAIL.value, { id: USERS_TAB as SideTab, icon: 'users' as UiIconName, labelKey: 'sidebar.users' }]
  : RAIL.value))
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
  if (next === ARCHIVE_TAB && tabForPath(route.path) !== ARCHIVE_TAB) await navigateTo(localePath('/archive'))
  if (next === ISSUES_TAB) await navigateTo(localePath('/issues'))
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
  if (id !== USERS_TAB && id !== EVENTS_TAB && id !== ISSUES_TAB && id !== ARCHIVE_TAB) sidePane.setCurrent(id)
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
const newDescriptionEl = ref<HTMLTextAreaElement | null>(null)
const descMp = useMentionPicker({ text: newDescription, el: newDescriptionEl })
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
/* owner, 2026-09-26: the version smaller, the commit smaller still, a tight gap */
const versionLabel = computed(() => String(version.value || '').trim())
const buildCommit = computed(() => String((build.value as { commit?: string } | null)?.commit || '').trim())
/* the card also opens by a tap (touch has no hover) and closes on Esc */
const vsOpen = ref(false)
const vsCopied = ref(false)
async function copyCommit() {
  try {
    await navigator.clipboard.writeText(buildCommit.value)
    vsCopied.value = true
    setTimeout(() => { vsCopied.value = false }, 1500)
  } catch { /* the text stays selectable by hand */ }
}
const buildMeta = computed(() => {
  const b = build.value as { built_at?: string, run?: string } | null
  if (!b) return ''
  return [b.built_at || '', b.run ? `run ${b.run}` : ''].filter(Boolean).join(' · ')
})

/* SPL-72, channels-v1 §5.4: Delete channel. Offered to its creator only; the
   hub refuses anyone else (403, or 404 to a non-member) whatever this shows. */
const selfId = computed(() => viewerHumanId(access.me, live.identity.value, { mock: api.mock, rosterMe: roster.me?.id || '' }))
const deleteOpen = ref(false)
const deleteTarget = ref({ channel_id: '', name: '' })
function deletableChannel(id: string) {
  const row = shownChannels.value.find((c) => c.channel_id === id)
  return !!row && canDeleteChannel({ selfId: selfId.value, row })
}
/* the confirm is LazyChannelDeleteDialog: off the initial script (027 §6) */
function askDeleteChannel(id: string) {
  const row = shownChannels.value.find((c) => c.channel_id === id)
  deleteTarget.value = { channel_id: id, name: String(row?.name || id) }
  deleteOpen.value = true
}
/* the open channel is gone: leave it for #lobby rather than show a 404 page */
function leaveDeleted(id: string) {
  if (channel.active === id) void navigateTo(localePath('/channel/lobby'))
}
function onChannelDeleted(id: string) {
  channelOrder.value = channelOrder.value.filter((k) => k !== id)
  flowOrder.value = flowOrder.value.filter((k) => k !== 'ch:' + id)
  leaveDeleted(id)
}
/* another member deleted it: every open sidebar drops the row (store), and a
   member reading it right now is taken to #lobby */
let offChannel: (() => void) | undefined
onMounted(() => {
  offChannel = live.onChannel((f) => {
    if (f.type === 'channel_deleted') leaveDeleted(String(f.channel || ''))
  })
})
onBeforeUnmount(() => { offChannel?.() })

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
.sidebar.sidebar--rail {
  width: max-content;
  max-width: var(--sidebar-w);
}
.sidebar.sidebar--rail .sidebar-body { display: none; }
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
/* SPL-979: a touch drag on an icon reorders instead of scrolling the page */
.sidebar-tab--movable { touch-action: none; }
.sidebar-tab--dragging { background: var(--color-surface-hover); color: var(--color-fg); cursor: grabbing; }
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
.mention-anchor { position: relative; display: flex; flex-direction: column; min-width: 0; }
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
/* Compact drop box (CLE-34991): one slim row, a glyph and the box, no
   caption. The select's width is the widest option in its own font, plus
   3px, plus the arrow (set from script, not a fixed px width). max-width
   keeps the row inside the sidebar. SPL-71: the name and the arrow sit in
   one bordered box (__field), a drop box rather than a dropdown menu. */
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
.tenant-switcher__icon { flex: 0 0 auto; display: inline-flex; }
.tenant-switcher__field {
  display: inline-flex;
  align-items: center;
  flex: 0 0 auto;
  min-width: 0;
  box-sizing: border-box;
  height: 24px;
  padding: 0 6px;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  cursor: pointer;
}
.tenant-switcher__error {
  margin: 0.125rem 0.5rem 0;
  font-size: 0.6875rem;
  color: var(--color-danger);
}
.tenant-switcher__select {
  flex: 0 0 auto;
  box-sizing: border-box;
  min-height: 22px;
  height: 22px;
  cursor: pointer;
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
/* SPL-980: the open list's rows get the same 2px before and after the name */
.tenant-switcher__select option { padding-inline: 2px; }
.tenant-switcher__arrow {
  flex: 0 0 auto;
  width: 0.65em;
  height: 0.5em;
  display: block;
  pointer-events: none;
  fill: currentColor;
  color: var(--color-fg);
}
/* SPL-989: the phone's level-1 header row, a 44 px target */
@media (max-width: 820px) {
  .tenant-switcher { min-height: var(--tap); }
  .tenant-switcher__field { min-height: calc(var(--tap) - 8px); }
}
.foot-row { display: flex; align-items: center; gap: 8px; padding: 8px 16px 4px; }
.foot-row .health { display: inline-flex; align-items: center; padding: 0 4px; }
.foot-row .vs-wrap { position: relative; flex: 1 1 auto; min-width: 0; display: flex; outline-offset: 2px; }
.foot-row .version-stamp {
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
  padding: 0 0 0 4px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  cursor: default;
}
/* the commit card: directly above the version (no gap to fall through),
   shown on hover / keyboard focus, hidden only 0.6 s after the pointer
   leaves both - long enough to move onto it and select the sha */
.foot-row .vs-pop {
  position: absolute;
  bottom: 100%;
  inset-inline-start: auto;
  inset-inline-end: 0;
  z-index: 30;
  display: flex;
  flex-direction: column;
  gap: 2px;
  max-width: min(360px, 90vw);
  padding: 6px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-surface, var(--color-bg));
  box-shadow: 0 4px 14px rgba(0, 0, 0, 0.18);
  font-family: var(--font-mono);
  font-size: 0.75rem;
  user-select: text;
  -webkit-user-select: text;
  visibility: hidden;
  opacity: 0;
  transition: opacity 0.15s ease 0.4s, visibility 0s linear 0.55s;
}
.foot-row .vs-wrap:hover .vs-pop,
.foot-row .vs-wrap:focus-within .vs-pop,
.foot-row .vs-wrap.is-open .vs-pop {
  visibility: visible;
  opacity: 1;
  transition-delay: 0s;
}
.foot-row .vs-pop__row { display: flex; align-items: center; gap: 6px; }
.foot-row .vs-pop__sha { white-space: nowrap; }
.foot-row .vs-pop__copy {
  font: inherit; font-family: var(--font-sans, inherit); font-size: 0.7rem;
  padding: 1px 6px; border: 1px solid var(--color-border); border-radius: var(--radius-sm);
  background: transparent; color: inherit; cursor: pointer;
}
.foot-row .vs-pop__meta { color: var(--color-muted); overflow-wrap: anywhere; }
/* em, so the font-size setting still scales both; the muted colour of
   .version-stamp keeps them readable on every theme */
.foot-row .vs-ver { font-size: 0.9em; }

/* SPL-989: level 1 on a phone - the icon rail becomes a strip of named
   sections across the top (44 px+ targets, scrolls sideways inside itself),
   the chosen section's list takes the full width below it. */
.sidebar-tab__label { display: none; }
@media (max-width: 820px) {
  .sidebar-main { flex-direction: column; }
  .sidebar-rail {
    flex-direction: row;
    width: 100%;
    max-width: 100%;
    padding: 4px 8px;
    border-inline-end: 0;
    border-bottom: 1px solid var(--color-border);
    overflow-x: auto;
    overflow-y: hidden;
    scrollbar-width: none;
  }
  .sidebar-tab {
    flex: 1 0 auto;
    width: auto;
    min-width: 60px;
    min-height: 52px;
    aspect-ratio: auto;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 2px;
    padding: 4px 6px;
    line-height: 1.15;
    container-type: normal;
  }
  .sidebar-tab :deep(svg) { width: 22px; height: 22px; }
  .sidebar-tab[aria-selected="true"] { background: var(--color-surface-hover); }
  .sidebar-tab__label { display: block; font-size: 0.6875rem; white-space: nowrap; }
  /* a sideways drag scrolls the strip; a long press still reorders */
  .sidebar-tab--movable { touch-action: pan-x; }
  .sidebar.sidebar--rail { width: 100%; max-width: 100%; }
  .sidebar-body { padding-top: 4px; }
  .nav-row > .nav-item { min-height: 48px; }
}
</style>
