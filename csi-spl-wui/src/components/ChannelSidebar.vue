<template>
  <nav class="sidebar" :class="{ 'sidebar--rail': issuesRailOnly || calendarRailOnly || monitoringRailOnly || reportingRailOnly || helpRailOnly || docsRailOnly, 'sidebar--strip': stripOnly }" :data-help-rail="helpRailOnly ? '1' : undefined" :data-docs-rail="docsRailOnly ? '1' : undefined">
    <div class="sidebar-main">
    <!-- The person's order (SPL-979, Settings → Behaviour → Left panel
         order; default: direct messages, channels, issues, flow,
         event log). Icons only; each name lives on aria-label and title.
         Dragging an icon reorders; a click navigates. Owner 2026-09-28
         (topic bea3a4e6): the app settings gear sits at the foot of this
         strip (no longer on the footer row beside the version), and Users
         is not a strip icon - the users CRUD is Settings -> Members. -->
    <div
      ref="railEl"
      class="sidebar-rail"
      data-testid="sidebar-rail"
    >
      <div
        class="sidebar-rail__tabs"
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
        :class="{ 'sidebar-tab--dragging': railDrag.draggingId.value === item.id, 'sidebar-tab--movable': item.movable }"
        role="tab"
        :data-testid="'sidebar-tab-' + item.id"
        :data-reorder-id="item.id"
        :aria-selected="railOn(item.id) ? 'true' : 'false'"
        :aria-controls="'sidebar-panel-' + item.id"
        :tabindex="tab === item.id ? 0 : -1"
        :aria-label="t(item.labelKey)"
        :title="t(item.labelKey)"
        :data-pinned="item.movable ? undefined : 'last'"
        v-tap-anim="railTapKind(item.id)"
        v-swell-up="railBadgeN(item.id)"
        @pointerdown="item.movable && railDrag.down($event, item.id as RailId)"
        @click="railClick(item.id)"
        @keydown="onTabKey"
      >
        <UiIcon :name="item.icon" :size="20" />
        <!-- SPL-989: the phone's level-1 strip names each section; hidden above 820 px -->
        <span class="sidebar-tab__label" aria-hidden="true">{{ t(item.labelKey) }}</span>
        <!-- spec 062: the Flow tab carries the hub's number (unseen + unread), 99+ above 99,
             as a neutral theme-grey badge (owner, t1 f4e6c677) -->
        <span v-if="item.id === 'flow' && flowLabel" class="sidebar-tab__count sidebar-tab__count--neutral" data-testid="sidebar-tab-flow-count" :aria-label="t('flow.badge', { n: flowLabel })">{{ flowLabel }}</span>
        <!-- owner (t1 f4e6c677): Channels and Direct messages carry the red number of new
             messages in the viewer's own discussions (the hub's Flow unread, split) -->
        <!-- t1 27b3ab77: a tap on the Issues number opens the list filtered to those issues -->
        <span v-else-if="railCount(item.id)" class="sidebar-tab__count" :class="{ 'sidebar-tab__count--link': item.id === 'issues' }" :data-testid="'sidebar-tab-' + item.id + '-count'" :aria-label="t('flow.badge', { n: railCount(item.id) })" @click="onCountClick(item.id, $event)">{{ railCount(item.id) }}</span>
        <span v-else-if="tabUnread(item.id)" class="sidebar-tab__pip" :data-testid="'sidebar-tab-' + item.id + '-unread'" aria-hidden="true" />
      </button>
      </div>
      <!-- W14 (spec 047): Help, one click for everyone; the gear below it -->
      <NuxtLink
        class="sidebar-rail__help"
        data-testid="help-open"
        v-tap-anim="'bounce'"
        :to="localePath('/help')"
        :data-current="railLinkOn('help') ? 'true' : undefined"
        :aria-current="railLinkOn('help') ? 'page' : undefined"
        :title="t('help.title')"
        :aria-label="t('help.title')"
      >
        <UiIcon name="help" :size="20" />
      </NuxtLink>
      <!-- Docs (Qto) (owner HUM-10, t1 4296200d): the workspace documents of
           spec 113 (/workspace/docs), for a signed-in member. SPL-1882 (t1
           2a2a4694): the one docs entry; the simple Docs (/docs) is gone -->
      <NuxtLink
        v-if="qtoShown"
        class="sidebar-rail__qto"
        data-testid="qto-open"
        v-tap-anim="'lift'"
        :to="localePath('/workspace/docs')"
        :data-current="railLinkOn('docs') ? 'true' : undefined"
        :aria-current="railLinkOn('docs') ? 'page' : undefined"
        :title="t('ws_doctree.open')"
        :aria-label="t('ws_doctree.open')"
      >
        <UiIcon name="file-text" :size="20" />
      </NuxtLink>
      <!-- SPL-1037 (specs/046): the app / tenant settings, admins and
           biz_owners only; owner 2026-09-28: a gear -->
      <NuxtLink
        v-if="tenantSettingsShown"
        class="sidebar-rail__settings"
        data-testid="tenant-settings-open"
        v-tap-anim="'bounce'"
        :to="localePath('/tenant-settings')"
        :data-current="railLinkOn('settings') ? 'true' : undefined"
        :aria-current="railLinkOn('settings') ? 'page' : undefined"
        :title="t('tenant_settings.title')"
        :aria-label="t('tenant_settings.title')"
      >
        <UiIcon name="settings" :size="20" />
      </NuxtLink>
      <!-- spec 074 T008 (owner HUM-10, t1 aa35699c): the operator console, a
           section of the right-most pane; only an admin of the operator
           workspace sees this (stores/operator-pane probes the list) -->
      <button
        v-if="operatorPane.visible"
        type="button"
        class="sidebar-rail__settings sidebar-rail__operator"
        data-testid="operator-console-open"
        v-tap-anim="'bounce'"
        :data-on="operatorPane.open ? 'true' : undefined"
        :aria-pressed="operatorPane.open ? 'true' : 'false'"
        :title="t('operator.open')"
        :aria-label="t('operator.open')"
        @click="operatorPane.toggle()"
      >
        <UiIcon name="building" :size="20" />
      </button>
      <!-- CLE-77886 (owner, msg 8ebbce0e): on a phone whose strip overflows,
           a copy of its controls on each side makes it roll endlessly
           (useLoopStrip). Copies only: no ids, no test ids, out of the tab
           order and hidden from assistive tech; a tap does what the real
           control does. -->
      <template v-if="loop.on.value">
        <div v-for="side in LOOP_SIDES" :key="side" class="sidebar-rail__loop" :data-loop="side" aria-hidden="true">
          <button
            v-for="item in rail"
            :key="item.id"
            type="button"
            class="sidebar-tab"
            tabindex="-1"
            :data-on="railOn(item.id) ? 'true' : undefined"
            v-tap-anim="railTapKind(item.id)"
            @click="railClick(item.id)"
          >
            <UiIcon :name="item.icon" :size="20" />
            <span class="sidebar-tab__label">{{ t(item.labelKey) }}</span>
            <span v-if="item.id === 'flow' && flowLabel" class="sidebar-tab__count sidebar-tab__count--neutral">{{ flowLabel }}</span>
            <span v-else-if="railCount(item.id)" class="sidebar-tab__count" :class="{ 'sidebar-tab__count--link': item.id === 'issues' }" @click="onCountClick(item.id, $event)">{{ railCount(item.id) }}</span>
            <span v-else-if="tabUnread(item.id)" class="sidebar-tab__pip" />
          </button>
          <NuxtLink v-tap-anim="'bounce'" class="sidebar-rail__help" tabindex="-1" :to="localePath('/help')" :data-current="railLinkOn('help') ? 'true' : undefined" :aria-current="undefined">
            <UiIcon name="help" :size="20" />
          </NuxtLink>
          <NuxtLink v-if="qtoShown" v-tap-anim="'lift'" class="sidebar-rail__qto" tabindex="-1" :to="localePath('/workspace/docs')" :data-current="railLinkOn('docs') ? 'true' : undefined" :aria-current="undefined">
            <UiIcon name="file-text" :size="20" />
          </NuxtLink>
          <NuxtLink v-if="tenantSettingsShown" v-tap-anim="'bounce'" class="sidebar-rail__settings" tabindex="-1" :to="localePath('/tenant-settings')" :data-current="railLinkOn('settings') ? 'true' : undefined" :aria-current="undefined">
            <UiIcon name="settings" :size="20" />
          </NuxtLink>
        </div>
      </template>
    </div>
    <!-- perf round 6 row 03 (SPL-2435): a rail-only page mounts no list -
         it was hidden by CSS, 137 nodes on /workspace/docs; the stores keep
         folds and unread, so the list comes back whole on leaving -->
    <div v-if="!railOnly" class="sidebar-body">
      <div
        v-if="tab === 'dm' || (tabsBuilt.dm && !phone)"
        v-show="tab === 'dm'"
        id="sidebar-panel-dm"
        class="sidebar-panel"
        role="tabpanel"
        aria-labelledby="sidebar-tab-dm"
        data-testid="sidebar-panel-dm"
      >
    <h2 class="sidebar-help" tabindex="0" data-testid="sidebar-help-dm" aria-describedby="sidebar-help-dm-tip">
      {{ t(dmLabelKey) }}
      <span id="sidebar-help-dm-tip" class="sidebar-help__tip" role="tooltip">{{ t('sidebar.help.direct_messages') }}</span>
    </h2>
    <div class="sidebar-scroll">
    <!-- the reader's own row. A signed-in human is the one peer
         guaranteed to be online, and was the only one the pane never drew -
         so "am I connected?" had no answer here at all. It is not a link:
         there is no DM with yourself, and the row exists to show presence. -->
    <div
      v-if="roster.self"
      class="nav-item self-row"
      data-testid="people-self"
      :data-key="roster.self.label"
      :aria-current="channel.peer ? undefined : 'true'"
      :title="t('auth.login.signed_in_as', { who: peerName(roster.self.id, roster.self.box) })"
    >
      <SpoolAvatar :id="roster.self.id" :box="roster.self.box" :size="22" />
      <!-- CLE-77862 (HUM-24): this dot is the READER's status, and says so;
           a DM's peer status is in the DM header, beside the peer's name. -->
      <StatusDot
        :id="roster.self.id"
        :online="roster.self.online"
        role="img"
        data-test="self-status-dot"
        :title="selfStatus"
        :aria-label="selfStatus"
      />
      <HumanName class="label" :id="roster.self.id" :box="roster.self.box" />
      <!-- `sidebar.you` carries its own brackets: a bracket hard-coded here
           lands on the wrong side of an RTL label (he), because the bidi
           algorithm resolves neutral punctuation from its surroundings. -->
      <span class="muted self-row__you">{{ t('sidebar.you') }}</span>
      <!-- spec 096 §7.5: the reader's own manual status, set from here -->
      <button
        type="button"
        class="self-row__status"
        data-testid="status-open"
        :aria-label="selfManual ? t('status.change', { status: selfManual.full }) : t('status.set')"
        :title="selfManual ? selfManual.full : t('status.set')"
        @click="statusPicker.show()"
      ><UiIcon name="smile" :size="16" /></button>
    </div>
    <div
      v-for="(p, peerIndex) in peers"
      :key="p.label"
      class="nav-row"
      :data-order="p.label"
      v-swell-up="unreadOf('dm:' + p.label)"
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
      @keydown="onDmRowKey"
    >
      <SpoolAvatar :id="p.id" :box="p.box" :size="22" />
      <StatusDot :id="p.id" :online="p.online" :idle="p.idle" />
      <HumanName class="label" :id="p.id" :box="p.box" stacked />
      <!-- 080 FR-005: a draft waits here; it shares the badge slot with the 079 unread -->
      <span v-if="hasDraft('dm:' + p.label)" class="draft-mark" data-testid="draft-mark" :title="t('composer.draft_mark')" :aria-label="t('composer.draft_mark')" role="img"><UiIcon name="pencil" :size="12" /></span>
      <span v-if="unreadOf('dm:' + p.label)" class="badge-unread" data-test="dm-badge">{{ dmBadgeLabel(p.label) }}</span>
      <span v-else-if="dmTotalLabel(p.label)" class="badge-total" data-test="dm-total">{{ dmTotalLabel(p.label) }}</span>
    </NuxtLink>
    <RowMutedButton v-if="mutedPeers[p.label]" :name="peerName(p.id, p.box)" @unmute="togglePeer('mute', p.label)" />
    <SidebarRowMenu
      :menu-id="'dm:' + p.label"
      :name="peerName(p.id, p.box)"
      :href="localePath('/dm/' + encodeURIComponent(p.label))"
      :unread="!!unreadOf('dm:' + p.label)"

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
        v-if="panelTab === 'channels' || (tabsBuilt.channels && !phone)"
        v-show="panelTab === 'channels'"
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
      :class="{ 'nav-row--muted': isChannelMuted(c.channel_id), 'nav-row--drag': dragging('channels', c.channel_id), 'nav-row--drop': dropping('channels', c.channel_id, channelIndex), 'nav-row--drop-after': droppingAfter('channels', channelIndex, channelRows.length), 'nav-row--move-over': moveLit('channels', c.channel_id), 'nav-row--move-denied': moveDenied('channels', c.channel_id) }"
      data-move-drop="channel"
      data-move-scope="channels"
      :data-move-id="c.channel_id"
      :data-move-ok="mover.drag.value ? String(moveTarget(c.channel_id)) : undefined"
      :data-move-denied-label="moveDenied('channels', c.channel_id) ? t('feed.move.not_allowed') : undefined"
      @pointerdown="rowPointerDown($event, 'channels', c.channel_id)"
      @contextmenu.prevent="openChannelMenu('ch:' + c.channel_id)"
      @click.capture="swallowDragClick"
    >
    <!-- draggable=false: a press-and-move on the link started the browser's
         own link drag, which cancels the pointer stream, so the reorder
         never finished (SPL-1034). A topic card's handle drag (SPL-1134)
         finds this row by data-move-drop under the pointer. -->
    <NuxtLink
      class="nav-item"
      draggable="false"
      :class="{ active: channel.active === c.channel_id }"
      :data-key="c.channel_id"
      :data-ts="channelActivity(c, channel.liveAt) || undefined"
      :title="c.description || undefined"
      :to="localePath('/channel/' + c.channel_id)"
      @click="keepRowFocus"
      @keydown="onChannelRowKey"
    >
      <span class="hash">#</span>
      <span class="label">{{ c.name }}</span>
      <span v-if="retentionLabel(c)" class="retention muted" :title="t('sidebar.retention_title', { retention: retentionLabel(c) })">{{ retentionLabel(c) }}</span>
      <!-- 080 FR-005: a draft waits here; it shares the badge slot with the 079 unread -->
      <span v-if="hasDraft('ch:' + c.channel_id)" class="draft-mark" data-testid="draft-mark" :title="t('composer.draft_mark')" :aria-label="t('composer.draft_mark')" role="img"><UiIcon name="pencil" :size="12" /></span>
      <span v-if="notes.mentions['ch:' + c.channel_id]" class="badge-mention" data-testid="mention-count">@{{ notes.previewUnread(notes.mentions['ch:' + c.channel_id]) }}</span>
      <span v-if="unreadOf('ch:' + c.channel_id)" class="badge-unread" data-testid="channel-unread">{{ notes.previewUnread(unreadOf('ch:' + c.channel_id)) }}</span>
    </NuxtLink>
    <RowMutedButton v-if="isChannelMuted(c.channel_id)" :name="c.name" @unmute="toggleChannelMute(c.channel_id)" />
    <SidebarRowMenu
      :menu-id="'ch:' + c.channel_id"
      :name="c.name"
      :href="localePath('/channel/' + c.channel_id)"
      :unread="!!unreadOf('ch:' + c.channel_id)"
      :channel="true"
      :properties="showProperties(c.channel_id)"
      :deletable="deletableChannel(c.channel_id)"
      :archivable="deletableChannel(c.channel_id)"
      :muted="isChannelMuted(c.channel_id)"
      :move-up="channelIndex > 0"
      :move-down="channelIndex < channelRows.length - 1"
      :open="rowMenu === 'ch:' + c.channel_id"
      @toggle="toggleRowMenu('ch:' + c.channel_id)"
      @close="closeRowMenu()"
      @open="navigateTo(localePath('/channel/' + c.channel_id))"
      @mark-read="notes.markRead('ch:' + c.channel_id)"
      @mute="toggleChannelMute(c.channel_id)"
      @properties="openProperties(c.channel_id)"
      @delete="askDeleteChannel(c.channel_id)"
      @archive-channel="askArchiveChannel(c.channel_id)"
      @move-up="stepChannel(c.channel_id, -1)"
      @move-down="stepChannel(c.channel_id, 1)"
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
        <button
          v-if="archivedSlug"
          type="button"
          class="btn ghost"
          data-testid="create-channel-unarchive"
          :disabled="creating"
          @click="unarchiveFromCreate"
        >{{ t('sidebar.create_channel_unarchive', { slug: archivedSlug }) }}</button>
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
    <LazyChannelConfirmDialog
      v-if="deleteTarget.channel_id"
      v-model:open="deleteOpen"
      action="delete"
      :channel-id="deleteTarget.channel_id"
      :name="deleteTarget.name"
      @done="onChannelDeleted"
    />
    <!-- rdb 0092: Archive channel, its creator only, always behind this confirm -->
    <LazyChannelConfirmDialog
      v-if="archiveTarget.channel_id"
      v-model:open="archiveOpen"
      action="archive"
      :channel-id="archiveTarget.channel_id"
      :name="archiveTarget.name"
      @done="onChannelArchived"
    />
      </div>
      <div
        v-if="tab === 'flow' || (tabsBuilt.flow && !phone)"
        v-show="tab === 'flow'"
        id="sidebar-panel-flow"
        class="sidebar-panel"
        role="tabpanel"
        aria-labelledby="sidebar-tab-flow"
        data-testid="sidebar-panel-flow"
      >
        <h2>{{ t('sidebar.flow') }}</h2>
        <!-- topic 635f8072: message entries, not a list of channels / agents / topics -->
        <LazyFlowList :active="tab === 'flow'" />
      </div>
      <!-- CLE-77884 (topic 635f8072): the /search hits, in the left panel. Not
           a rail tab: shown by a search and held while the reader opens hits
           (holdSearch); a rail icon or its X clears it. On a phone the search
           page itself is this list (level 2), so it is not built twice. -->
      <div
        v-if="tab === 'search' && !(mobileStack.isMobile.value && onSearchPage)"
        id="sidebar-panel-search"
        class="sidebar-panel"
        role="tabpanel"
        data-testid="sidebar-panel-search"
      >
        <SearchSidePanel @close="closeSearch" />
      </div>
      <!-- Issues, third rail tab. The list is the middle pane. -->
      <div
        v-if="tab === 'issues' || (tabsBuilt.issues && !phone)"
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
      <!-- CLE-77794: People - every tenant member. The list is here; the chosen
           person's card (avatar, role, last seen, interests) opens in the
           middle pane at /people/<id>, like a DM feed. -->
      <div
        v-if="tab === 'people' || (tabsBuilt.people && !phone)"
        v-show="tab === 'people'"
        id="sidebar-panel-people"
        class="sidebar-panel"
        role="tabpanel"
        aria-labelledby="sidebar-tab-people"
        data-testid="sidebar-panel-people"
      >
        <h2 class="sidebar-help" tabindex="0" data-testid="sidebar-help-people" aria-describedby="sidebar-help-people-tip">
          {{ t('sidebar.people') }}
          <span id="sidebar-help-people-tip" class="sidebar-help__tip" role="tooltip">{{ t('sidebar.help.people') }}</span>
        </h2>
        <div class="sidebar-scroll">
          <p v-if="memberRows.length === 0" class="muted topic-empty">{{ t('people.none') }}</p>
          <div v-for="p in memberRows" :key="p.id" class="nav-row">
            <NuxtLink
              class="nav-item"
              :class="{ active: peopleOpen === p.id }"
              :aria-current="peopleOpen === p.id ? 'true' : undefined"
              :data-key="p.id"
              :data-online="p.online ? '1' : '0'"
              :to="localePath('/people/' + encodeURIComponent(p.id))"
            >
              <SpoolAvatar :id="p.id" :box="p.box" :size="22" />
              <StatusDot :id="p.id" :online="p.online" />
              <span class="people-row__who">
                <HumanName class="label" :id="p.id" :box="p.box" />
                <!-- spec 096 §5: the status note under the name, one line -->
                <span v-if="humanStatus.statusLabel(p.id, t)" class="muted people-row__status" data-testid="people-status">{{ humanStatus.statusLabel(p.id, t)?.full }}</span>
              </span>
              <span v-if="p.self" class="muted people-row__tag">{{ t('sidebar.you') }}</span>
              <span v-else-if="p.owner" class="muted people-row__tag">{{ t('people.owner') }}</span>
            </NuxtLink>
          </div>
        </div>
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
          <span v-reconnect-ripple="health" class="health-dot" :class="health" />
        </div>
        <NotificationCenter />
        <!-- The version sits on this row, just right of the note. Only the
             version is painted. Hover or click opens the commit, and it stays
             while the pointer is on it so the hash can be copied. -->
        <span
          ref="vsWrapEl"
          class="vs-wrap"
          :class="{ 'is-open': vsOpen }"
          tabindex="0"
          data-test="app-version-wrap"
          :aria-label="versionText || undefined"
          :aria-expanded="vsOpen"
          :style="vsPlace"
          @mouseenter="placeVsPop"
          @focusin="placeVsPop"
          @click="toggleVsPop"
          @keydown.esc.stop="closeVsPop"
        >
          <p id="app-version" class="version-stamp" data-test="app-version"><span class="vs-ver">{{ versionLabel }}</span></p>
          <span v-if="buildCommit" class="vs-pop" role="tooltip" data-test="app-version-card">
            <span class="vs-pop__row">
              <span class="vs-pop__sha">{{ buildCommit }}</span>
              <!-- SPL-999: the code blocks' copy icon; "Copied" shows beside the check -->
              <button
                type="button"
                class="vs-pop__copy"
                data-test="app-version-copy"
                :title="vsCopied ? t('code.copied') : t('code.copy')"
                :aria-label="vsCopied ? t('code.copied') : t('code.copy')"
                @click.stop="copyCommit"
              >
                <UiIcon :name="vsCopied ? 'check' : 'copy'" :size="15" />
                <span v-if="vsCopied" class="vs-pop__copied" aria-live="polite">{{ t('code.copied') }}</span>
              </button>
            </span>
            <span v-if="buildMeta" class="vs-pop__meta">{{ buildMeta }}</span>
            <!-- SPL-1006: this tab runs buildCommit; say when a newer one is live -->
            <span v-if="newerLive" class="vs-pop__newer" data-test="app-version-newer">
              <span>{{ t('build.newer_live', { commit: newerLive }) }}</span>
              <button type="button" class="vs-pop__reload" data-test="app-version-reload" @click.stop="reloadForBuild(buildWatch.live)">{{ t('build.reload') }}</button>
            </span>
            <!-- SPL-1787 (owner HUM-10, t1 03fc4a65 msg 833bccea): "Powered by
                 Csitea" on the left, the Release notes on the right -->
            <span class="vs-pop__foot" data-test="app-version-foot">
              <PoweredBy class="vs-pop__powered" />
              <!-- spec 065 L6: every version and its commits' notes, one modal -->
              <button type="button" class="vs-pop__reload" data-test="app-version-notes" @click.stop="releaseNotesOpen = true">{{ t('release_notes.open') }}</button>
            </span>
          </span>
        </span>
        <!-- owner, t1 be316fdc: the last-updated clock right of the version, at
             the row's end (t1 7b48293b), while this row is on screen (useClockHost: else the phone strip
             or the top bar has it - one clock, one listener per screen) -->
        <LastDataClock v-if="clockHost.foot.value" class="foot-row__clock" />
      </div>
      <!-- identity, Sign in / Sign out: the top-right UserMenu -->
    </div>
    </div>
    </div>
    <!-- SPL-1204: like LazyChannelConfirmDialog above, gate on the target so the
         async chunk loads on the first Properties open, not on every sidebar
         mount; it stays mounted after (channel_id persists) so the close
         animation still plays. -->
    <ChannelPropertiesDialog
      v-if="propertiesChannel.channel_id"
      v-model:open="propertiesOpen"
      :channel-id="propertiesChannel.channel_id"
      :name="propertiesChannel.name"
      :description="propertiesChannel.description"
      :created-by="propertiesChannel.created_by"
    />
    <!-- 050: the channels panel's collapse triangle, bottom corner. A DIRECT
         child of .sidebar so the collapse CSS hides its siblings and keeps only
         this strip. -->
    <PaneCollapseToggle pane="channels" />
    <LazyReleaseNotesDialog v-if="releaseNotesOpen" v-model:open="releaseNotesOpen" />
  </nav>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import type { Directive } from 'vue'
import { playTapAnim, railTapKind, vTapAnim } from '~/composables/useTapAnim'
import { vReconnectRipple } from '~/composables/useConnectionRipple'
import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import { useHumanStatusStore } from '~/stores/human-status'
import { useStatusPicker } from '~/composables/useStatusPicker'
import { useSessionStore } from '~/stores/session'
import { useAccessStore } from '~/stores/access'
import { useSearchStore } from '~/stores/search'
import { isSignedOutVisitor } from '~/utils/shell-bootstrap.mjs'
/* Async: it carries @headlessui/vue + @tanstack/virtual-core
   (~17 KB gzip) that no first paint needs; it loads right after the shell. */
const ChannelPropertiesDialog = defineAsyncComponent(() => import('~/components/ChannelPropertiesDialog.vue'))
/* CLE-77884: async too - only a search needs it */
const SearchSidePanel = defineAsyncComponent(() => import('~/components/SearchSidePanel.vue'))
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useNotificationStore } from '~/stores/notification'
import { useLive } from '~/composables/useLive'
import HumanName from '~/components/HumanName.vue'
import LastDataClock from '~/components/LastDataClock.vue'
import PoweredBy from '~/components/PoweredBy.vue'
import { channelActivity, connectionHealth, retentionDays, shownPerson } from '~/utils/channel-feed.mjs'
import { feedbackChannelCopy } from '~/utils/feedback-channel'
import { reloadForBuild } from '~/composables/useBuildWatch'
import { useSidePane } from '~/composables/useSidePane'
import { useMobileStack } from '~/composables/useMobileStack'
import { useLoopStrip } from '~/composables/useLoopStrip'
import { useSectionExit } from '~/composables/useSectionExit'
import { railLinkSection } from '~/utils/section-strip.mjs'
import { ARCHIVE_TAB, CALENDAR_TAB, ISSUES_TAB, MONITORING_TAB, PEOPLE_TAB, REPORTING_TAB, USERS_TAB, isSearchPage, tabForPath } from '~/utils/sidebar-tabs.mjs'
import { setLinkOpenHook } from '~/utils/msg-jump.mjs'
import { isHumanId } from '~/utils/agent-kind.mjs'
import { RAIL_TABS, isRailMovable, railLabelKey, type RailId } from '~/utils/rail-order'
import { useRailOrder } from '~/composables/useRailOrder'
import { useDragReorder } from '~/composables/useDragReorder'
import { useMove } from '~/composables/useMove'
import { isChannelDropTarget } from '~/utils/move.mjs'
import { tenantSettingsVisible } from '~/utils/tenant-settings-nav'
import { useOperatorPane } from '~/stores/operator-pane'
import { useHumanNames } from '~/composables/useHumanNames'
import { loadHiddenPeers, pinRows, rowMenuAdmin } from '~/utils/sidebar-row-menu.mjs'
import { useUnreadOrder } from '~/composables/useUnreadOrder'
import { useChannelOrder } from '~/composables/useChannelOrder'
import { useSidebarCounts } from '~/composables/useSidebarCounts'
import { useSidebarPeers } from '~/composables/useSidebarPeers'
import { useSidebarChannelAdmin } from '~/composables/useSidebarChannelAdmin'
import { useSidebarChannelCreate } from '~/composables/useSidebarChannelCreate'
import { useSidebarRowDrag } from '~/composables/useSidebarRowDrag'
import { useSidebarRowKeys } from '~/composables/useSidebarRowKeys'
import { useSidebarRailOnly } from '~/composables/useSidebarRailOnly'
import { useSidebarRailTabKeys } from '~/composables/useSidebarRailTabKeys'
import { useSidebarRailNav } from '~/composables/useSidebarRailNav'
import { useSidebarVersion } from '~/composables/useSidebarVersion'
import type { UiIconName } from '~/utils/uiIcons'

type SideTab = 'dm' | 'channels' | 'flow' | 'search' | 'issues' | 'archive' | 'users' | 'people' | 'calendar' | 'monitoring' | 'reporting'
/* The six rail tabs (utils/rail-order.ts RAIL_TABS) in the person's order
   (SPL-979). A matching route follows the page; search and settings keep the
   reader's choice. */
const railOrder = useRailOrder()
const railEl = ref<HTMLElement | null>(null)
const railDrag = useDragReorder<RailId>({
  order: () => railOrder.order.value,
  items: () => [...(railEl.value?.querySelectorAll<HTMLElement>('[data-reorder-id]') || [])],
  onDrop: (next) => { void railOrder.save(next) },
  normalize: railOrder.normalize,
  /* t1 7b48293b: on the phone strip a swipe scrolls; a long press reorders */
  touchHoldMs: 450,
})
const RAIL_BY_ID = new Map(RAIL_TABS.map((item) => [item.id, item]))
/* CLE-77904 (owner, t1 topic cb12574f): on a phone the DM section is named
   "Messages" (railLabelKey); above 820 px it stays "Direct messages" */
const phone = useMobileStack().isMobile
const RAIL = computed(() => (railDrag.preview.value || railOrder.order.value)
  .map((id) => RAIL_BY_ID.get(id))
  .filter((item): item is (typeof RAIL_TABS)[number] => Boolean(item))
  /* CLE-77916 (owner, t1 topic 5463df22): Archive is last and not draggable */
  .map((item) => ({ id: item.id as SideTab, icon: item.icon as UiIconName, labelKey: railLabelKey(item, phone.value), movable: isRailMovable(item.id) })))
const dmLabelKey = computed(() => railLabelKey(RAIL_BY_ID.get('dm') || { labelKey: 'sidebar.direct_messages' }, phone.value))
const tab = ref<SideTab>('dm')
/* the first render builds the open rail tab only. The other tabs
   (a v-show each) were built with it and hidden: on / the flow tab alone was
   915 nodes nobody sees, on /lobby the hidden tabs were 30 % of the page.
   CLE-77934: a tab is built the first time it is opened and kept from then
   on (a switch back shows it at once). They used to be built all together
   on the first idle (at most 1.5 s in): ~2 000 nodes in one task, just as
   the reader reached for the rail. Measured with do_spl_wui_perf_first_load
   (dev host, local bundles, A/B interleaved, n=10): first-screen DOM
   3 739 -> 2 165 nodes (phone 3 880 -> 2 554); main-thread JS between the
   rail and the Flow list 4.6 -> 0.5 s (phone CPU 4x: 2.2 -> 0.5 s). */
/* E08: on a phone a kept panel is still in the document and hidden (the
   DM list was 112 hidden nodes after Flow opened). Mount it only while it
   is the open tab. Desktop keeps tabsBuilt so a switch back is instant. */
const tabsBuilt = reactive<Partial<Record<SideTab, boolean>>>({})
onMounted(() => { tabsBuilt[panelTab.value] = true })
function peerName(id: string, box?: string) {
  return shownPerson(id, box, people.names.value)
}
const rowMenu = ref('')
function toggleRowMenu(id: string) {
  rowMenu.value = rowMenu.value === id ? '' : id
}
function closeRowMenu() { rowMenu.value = '' }
function openChannelMenu(id: string) { rowMenu.value = id }
/* The flow list stays up while a row from it is opened. Another icon clears it. */
const holdFlow = ref(false)
/* CLE-77884: so does the search list while the reader opens its hits; a
   navigation from anywhere else (a rail icon, a link, Open parent section)
   lets the rail follow the page again */
const holdSearch = ref(false)
const searchStore = useSearchStore()
const route = useRoute()
const mobileStack = useMobileStack()
const onSearchPage = computed(() => isSearchPage(route.path))
/* the list panel 1 shows: the rail tab's own (the Topics tab, which showed
   Channels on `/`, is gone: owner t1 e4bfddb1) */
const panelTab = computed<SideTab>(() => tab.value)
/* not immediate: the route sets the real tab during setup, so the 'dm' the
   ref starts with is never built unless it is shown */
watch(panelTab, (open) => { tabsBuilt[open] = true })
watch(() => route.path, (path, prev) => {
  rowMenu.value = ''
  if (isSearchPage(path)) {
    holdFlow.value = false
    holdSearch.value = true
    tab.value = 'search'
    return
  }
  /* CLE-77882: a message opened in place keeps the list it was opened from */
  const held = useSidePane().listHeld.value
  if (holdSearch.value && !held && !searchStore.opening) holdSearch.value = false
  if (holdFlow.value || held || holdSearch.value) return
  /* SPL-989: on a phone at level 1 this list IS the screen - Back to it
     keeps the section the reader left from, whatever page sits behind. The
     first load is not a Back: `/` opens on Channels (t1 e4bfddb1). */
  if (prev !== undefined && mobileStack.isMobile.value && mobileStack.level.value === 1) return
  const next = tabForPath(path)
  if (next) tab.value = next
}, { immediate: true })
/* HUM-10 (t1 36ea84a6): a followed link to a message or a topic shows its
   place's own list (Channels or Direct messages), not the Flow or the search
   list it was read from. The Flow's and Search's own opens keep their list. */
setLinkOpenHook((path: string) => {
  if (!/^(?:\/[^/]+)?\/(?:channel|dm|m)\//.test(path)) return
  holdFlow.value = false
  holdSearch.value = false
  /* the same address again changes no route: the tab follows the link here */
  const next = tabForPath(path.split(/[?#]/)[0])
  if (next) tab.value = next
})
onBeforeUnmount(() => setLinkOpenHook(null))
const channel = useChannelStore()
const roster = useRosterStore()
const session = useSessionStore()
const access = useAccessStore()
const api = useSpoolApi()
// specs/054 (owner 18597eaa: "no of course"): while acting as a member the
// clone must never see the person's DMs, so the DM rail tab and its peers are
// hidden (the hub also 403s every DM endpoint for a clone).
const acting = computed(() => Boolean(access.me?.actAs))
const signedOut = computed(() => isSignedOutVisitor(session.state, api.mock))
/* Docs (Qto): a signed-in member only; the mock's settled session is 'unknown'
   (read as signed in), 'out' when an e2e opts into a signed-out visitor */
const qtoShown = computed(() => (api.mock ? session.state !== 'out' : session.state === 'in'))
const notes = useNotificationStore()
const live = useLive()
const { t, te } = useI18n({ useScope: 'global' })
/* CLE-77862: the tooltip / accessible name of the reader's own status dot */
/* spec 096: the reader's manual status rides the same words, after presence */
const statusPicker = useStatusPicker()
const humanStatus = useHumanStatusStore()
const selfManual = computed(() => humanStatus.statusLabel(roster.self?.id || '', t))
const selfStatus = computed(() => {
  const presence = t(roster.self?.online ? 'sidebar.your_status_online' : 'sidebar.your_status_offline')
  return selfManual.value ? `${presence} · ${selfManual.value.full}` : presence
})
/* SPL-976: the description's submit key creates the channel, as the button does */
const { onKeydown: onSubmitKey } = useSubmitKey()
const localePath = useLocalePath()
/* the pages that keep the icon rail alone, .sidebar--rail (useSidebarRailOnly) */
const { issueEpics, issuesRailOnly, calendarRailOnly, monitoringRailOnly, reportingRailOnly, helpRailOnly, docsRailOnly, railOnly } = useSidebarRailOnly(tab, mobileStack.isMobile, route)
/* owner 2026-09-28 (topic bea3a4e6): no Users icon - the users CRUD is
   reached only through the settings gear (Settings -> Members) */
const tenantSettingsShown = computed(() => tenantSettingsVisible(access.me, { mock: api.mock }))
/* spec 074 T008: probe the operator list once the reader's role is known.
   SPL-1797: wait for /v1/view/me first; a probe sent before it answered gave
   every member a 403 on the operator route (load() shares its pending read).
   SPL-1804: only while me has not answered; a known guest (role null) must
   not re-read it, or the read overwrites the guest with the member it was. */
const operatorPane = useOperatorPane()
watch(() => [session.state, access.me?.role ?? null] as const, async ([st]) => {
  if (st !== 'in' && !api.mock) return
  if (!access.me) await access.load()
  void operatorPane.probe(access.me?.role ?? null)
}, { immediate: true })
const rail = computed(() => (acting.value ? RAIL.value.filter((item) => item.id !== 'dm') : RAIL.value))
// specs/054: the DM tab is hidden while acting; never leave it selected.
watch(acting, (a) => { if (a && tab.value === 'dm') tab.value = 'channels' }, { immediate: true })
const railLabel = computed(() => rail.value.map((item) => t(item.labelKey)).join(', '))
/* spec 109 FR-012: Settings -> Behaviour -> "Show labels" (RailOrderSetting),
   default off, kept in this browser: <html class="rail-labels"> names the
   desktop rail's icons (main.css); the phone strip always names them */
onMounted(() => {
  try { document.documentElement.classList.toggle('rail-labels', localStorage.getItem('spool.rail-labels') === '1') } catch { /* storage blocked: off */ }
})
/* CLE-77886 (owner, t1 topic ac0fa400): on a phone a section's own page
   keeps this strip on top (layouts/default.vue data-mobile-section); the
   sidebar then shows the strip only. On Help / Workspace settings - rail
   links, not tabs - no tab reads as selected on a phone: the link does. */
const sectionExit = useSectionExit()
watch(() => route.fullPath, () => sectionExit.note(route.path, route.fullPath), { immediate: true })
/* SPL-3785: at every level past 1 (the layout's sectionStrip), not only on a section's own page */
const stripOnly = computed(() => mobileStack.isMobile.value && mobileStack.level.value !== 1)
const onRailLink = computed(() => stripOnly.value && Boolean(railLinkSection(route.path)))
/* the rail and section navigation: a rail tab's click, the Issues number, the search list's X (useSidebarRailNav) */
const { selectTab, railClick, closeSearch, onCountClick } = useSidebarRailNav({ tab, holdFlow, holdSearch, stripOnly, onRailLink, helpRailOnly, docsRailOnly })
/* spec 103 T006: Enter, the arrows, Home and End on a rail tab (useSidebarRailTabKeys) */
const { onTabKey } = useSidebarRailTabKeys({ phone, tab, rail, railClick, selectTab })
function railOn(id: SideTab) {
  return tab.value === id && !onRailLink.value
}
/* SPL-2434 (owner HUM-10, t1 3cdd22b6: "a weird double selection in the top
   row icons"): Help, Docs (Qto) and the gear read as selected only while
   their page is the pane shown. On a phone a tap on Channels from Workspace
   settings shows the Channels list at level 1 and leaves the route on
   /tenant-settings, so the router's active class kept the gear raised beside
   Channels. Above 820 px the page is always shown. */
function railLinkOn(section: 'help' | 'docs' | 'settings') {
  if (railLinkSection(route.path) !== section) return false
  return !mobileStack.isMobile.value || onRailLink.value
}
const LOOP_SIDES = ['before', 'after'] as const
const loop = useLoopStrip(railEl, {
  enabled: () => mobileStack.isMobile.value,
  selected: '.sidebar-tab[aria-selected="true"], [data-current="true"]:not([tabindex="-1"])',
  watchKey: () => [tab.value, route.path, mobileStack.level.value, rail.value.length, tenantSettingsShown.value, qtoShown.value],
})
/* the rail's numbers and a row's unread / draft / DM badge (useSidebarCounts) */
const { flowLabel, flowKeys, unreadOf, hasDraft, dmBadgeLabel, dmTotalLabel, railCount, tabUnread, countsLoaded } = useSidebarCounts(api, live,
  () => channelRows.value.map((c) => String(c.channel_id || '')), () => peers.value.map((p) => p.label))
/* row 04 of ui-animations-panel-plan.md (SPL-2736): a rail tab's unread
   number or pip, and a DM row's badge, swell once when the number goes up.
   The host stays mounted, so an equal re-render and a fall play nothing;
   SPL-2815: the counts arrive after mount, so nothing plays until the first
   ones are on screen (countsLoaded): the first load is the first paint.
   playTapAnim does nothing under reduced motion or on a hidden badge. */
const vSwellUp: Directive<HTMLElement, number> = {
  updated(el, { value, oldValue }) {
    const badge = countsLoaded.value && value > (oldValue || 0) && el.querySelector<HTMLElement>('.badge-unread, .sidebar-tab__count, .sidebar-tab__pip')
    if (badge) playTapAnim(badge, 'swell')
  },
}
/* the number a rail tab's badge shows ("99+" reads 99); a pip counts 1 */
function railBadgeN(id: string) {
  return parseInt(id === 'flow' ? flowLabel.value : railCount(id)) || +tabUnread(id)
}
const sidePane = useSidePane()
watch(() => sidePane.requested.value, (req) => {
  if (!req) return
  /* reveal: show the list and stay on this page, so the topic that just
     opened remains the one the omnibox writes into. */
  if (req.stay) {
    holdFlow.value = false
    holdSearch.value = false
    tab.value = req.id
    return
  }
  void selectTab(req.id)
})
watch(tab, (id) => {
  rowMenu.value = ''
  if (id !== 'search' && id !== USERS_TAB && id !== ISSUES_TAB && id !== ARCHIVE_TAB && id !== PEOPLE_TAB && id !== CALENDAR_TAB && id !== MONITORING_TAB && id !== REPORTING_TAB) sidePane.setCurrent(id)
}, { immediate: true })
/** Socket state token (open, reconnecting, …) in words; an unknown token (a config error) shows as is. */
const stateLabel = (s: string) => (te('feed.live_state.' + s) ? t('feed.live_state.' + s) : s)
/** "7 d" for #alerts (spec 005 FR-012), in the active locale; '' for every other channel. */
function retentionLabel(c: { channel_id?: string, channel?: string, retention_days?: number }) {
  const n = retentionDays(c)
  return n ? t('sidebar.retention_days', { n }) : ''
}
const health = computed(() => connectionHealth(live.state.value))
/* SPL-1034: the Channels order is the person's, kept on the hub (per tenant) */
const { order: channelOrder, set: setChannelOrder, step: stepChannelOrder } = useChannelOrder()
const peerAdmin = computed(() => rowMenuAdmin(access.me))
/* A person's chosen display name; the id@box stays the key and the tooltip. */
const people = useHumanNames()
/* the Direct messages rows and their menu (useSidebarPeers) */
const { listHidden, blockedPeers, mutedPeers, pinnedPeers, peers, togglePin, togglePeer, removePeer, hideFromList } = useSidebarPeers(api, live, acting, flowKeys, unreadOf)
/* CLE-77794: People lists every tenant member (the reader too, marked "you"),
   read from the same roster the DM list does, so no extra fetch. (Its Agents
   twin went into Monitoring, SPL-2075.) */
const memberRows = computed(() => roster.people
  .filter((p) => isHumanId(p.id))
  .map((p) => ({ ...p, owner: roster.owners.includes(p.id) || Boolean(roster.humansDetail[p.id]?.owner) })))
/* the open card's key, so its row reads as selected (aria-current) */
const peopleOpen = computed(() => {
  const m = route.path.match(/\/people\/([^/]+)$/)
  return m ? decodeURIComponent(m[1]) : ''
})
/** #feedback shows its locale name and description; a stored description wins. */
const shownChannels = computed(() => channel.ordered.map((c) => {
  const copy = feedbackChannelCopy(c.channel_id, {
    name: t('channels.feedback.name'),
    description: t('channels.feedback.description'),
  }, c.description)
  if (!copy) return c
  return { ...c, name: copy.name, description: copy.description }
}))
/* SPL-2506: channels with unread at the edge new posts go to (Message order), the most at the very edge */
const unreadOrder = useUnreadOrder()
const channelRows = computed(() => unreadOrder.order(pinRows(
  shownChannels.value,
  channelOrder.value,
  (c) => String(c.channel_id || ''),
), (c) => unreadOf('ch:' + c.channel_id)))

/* a held row re-orders its list (useSidebarRowDrag) */
const { dragging, dropping, droppingAfter, rowPointerDown, swallowDragClick } = useSidebarRowDrag(pinnedPeers, channelOrder, setChannelOrder)
/* SPL-1034 keyboard / touch: Move up / Move down in a channel row's menu */
function stepChannel(id: string, step: -1 | 1) {
  void stepChannelOrder(channelRows.value.map((c) => String(c.channel_id || '')), id, step)
}
/* HUM-10 (t1 7d9e1681), spec 103 T006: the channel / DM row keys (useSidebarRowKeys) */
const { keepRowFocus, onChannelRowKey, onDmRowKey } = useSidebarRowKeys(phone)

/* SPL-1024 / SPL-1134 (specs/045 §3.1, §3.9): a topic card dragged by its
   handle drops on a channel row. The rows only say whether they may take it
   (data-move-ok: listed for the viewer, not the one it is in, not the lobby,
   not `issues`); useMove reads the ONE row under the pointer, so exactly one
   is lit, and a row that may not take it says "not allowed" instead. */
const mover = useMove()
function moveTarget(id: string) {
  return isChannelDropTarget(mover.drag.value, id, channel.channels)
}
function moveLit(scope: string, id: string) {
  const o = mover.over.value
  return !!o && o.kind === 'channel' && o.ok && o.scope === scope && o.id === id
}
function moveDenied(scope: string, id: string) {
  const o = mover.over.value
  return !!o && o.kind === 'channel' && !o.ok && o.scope === scope && o.id === id
}
onMounted(() => {
  /* the route middleware has usually probed already; a second probe on every
     page load was one more session read for nothing */
  if (session.state === 'loading' || session.state === 'unknown') void session.probe()
  listHidden.value = loadHiddenPeers()
})
/* specs/025 FR-008: the role decides which actions are offered (the hub re-checks). */
watch(() => session.state, (st) => { if (st === 'in') access.load() }, { immediate: true })
/* the New channel dialog (useSidebarChannelCreate) */
const newDescriptionEl = ref<HTMLTextAreaElement | null>(null)
const { newChannel, newDescription, descMp, createOpen, creating, createError, slug, canCreate, openCreate, archivedSlug, unarchiveFromCreate, onCreate } = useSidebarChannelCreate(signedOut, newDescriptionEl)
/* the footer version, its card and the clock's host (useSidebarVersion) */
const vsWrapEl = ref<HTMLElement | null>(null)
const { buildWatch, newerLive, versionText, versionLabel, buildCommit, vsOpen, releaseNotesOpen, closeVsPop, toggleVsPop, placeVsPop, clockHost, vsPlace, vsCopied, copyCommit, buildMeta } = useSidebarVersion(phone, mobileStack, vsWrapEl)

/* a channel row's mute, Properties, Delete and Archive (useSidebarChannelAdmin) */
const { propertiesOpen, propertiesChannel, isChannelMuted, toggleChannelMute, showProperties, openProperties, deleteOpen, deleteTarget, deletableChannel, askDeleteChannel, archiveOpen, archiveTarget, askArchiveChannel, onChannelArchived, onChannelDeleted } = useSidebarChannelAdmin(api, live, shownChannels, channelOrder)

</script>

<style scoped>
.sidebar.sidebar--rail {
  width: max-content;
  max-width: var(--sidebar-w);
}
/* the tablist is only a semantic wrapper: the tabs stay flex items of the strip */
.sidebar-rail__tabs { display: contents; }
/* Help and the settings gear: the foot of the strip (bottom-left of the
   screen); Help takes the push, the gear sits under it */
.sidebar-rail__help { margin-block-start: auto; }
.sidebar-rail__help,
.sidebar-rail__qto,
.sidebar-rail__settings {
  display: grid;
  place-items: center;
  width: 100%;
  max-width: 100%;
  aspect-ratio: 1;
  border-radius: var(--radius-sm);
  color: var(--color-muted);
  container-type: size;
}
.sidebar-rail__help:hover,
.sidebar-rail__qto:hover,
.sidebar-rail__settings:hover { background: var(--color-surface-hover); color: var(--color-fg); }
.sidebar-rail__help[data-current="true"],
.sidebar-rail__qto[data-current="true"],
.sidebar-rail__settings[data-current="true"] { color: var(--color-fg); }
.sidebar-rail__help :deep(svg),
.sidebar-rail__qto :deep(svg),
.sidebar-rail__settings :deep(svg) {
  width: min(22px, 70cqi);
  height: min(22px, 70cqi);
}
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
/* the current section: its icon 1px smaller on every side and a shade darker
   than the rest (HUM-10, topic a3c2cf08): darkened from --color-muted, the
   other icons' colour, so it is darker in the dark theme too */
.sidebar-tab[aria-selected="true"] :deep(svg) {
  width: calc(min(22px, 70cqi) - 2px);
  height: calc(min(22px, 70cqi) - 2px);
  color: color-mix(in srgb, var(--color-muted) 75%, #000);
}
/* SPL-979: a touch drag on an icon reorders instead of scrolling the page */
.sidebar-tab--movable { touch-action: none; }
.sidebar-tab--dragging { background: var(--color-surface-hover); color: var(--color-fg); cursor: grabbing; }
.sidebar-tab :deep(svg) {
  width: min(22px, 70cqi);
  height: min(22px, 70cqi);
}
.sidebar-tab__count {
  position: absolute;
  top: 0;
  inset-inline-end: 0;
  min-width: 16px;
  height: 16px;
  padding: 0 4px;
  box-sizing: border-box;
  border-radius: var(--radius-pill);
  background: var(--color-danger);
  color: var(--color-danger-fg);
  font-size: 0.625rem;
  font-weight: 700;
  line-height: 16px;
  text-align: center;
  pointer-events: none;
}
/* t1 27b3ab77: the Issues number is its own target (the filtered list); a
   wider invisible edge keeps it easy to hit with a finger */
.sidebar-tab__count--link { pointer-events: auto; cursor: pointer; }
.sidebar-tab__count--link::before { content: ''; position: absolute; inset: -6px; }
/* owner (t1 f4e6c677): the Flow number is no alarm - the theme's grey, a
   step darker than the background (lighter on the dark theme), edged */
.sidebar-tab__count--neutral {
  background: var(--color-bg-3);
  color: var(--color-fg);
  box-shadow: inset 0 0 0 1px var(--color-border-strong);
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
/* CLE-77794: the trailing tag on a People row ("you" / "Owner"); it shrinks
   last so the name keeps the width, and the 72px rail hides it like the DM tail. */
.people-row__tag { margin-inline-start: auto; font-size: 11px; flex-shrink: 0; }
/* the reader's own row is a status line, not a destination: no pointer, no
   hover highlight, nothing that reads as "click me" */
.self-row { cursor: default; }
.self-row:hover { background: transparent; }
/* shrinks last, after the id: which row is yours matters more than the tail
   of a long label, and the 72px rail hides both (main.css max-width 800) */
.self-row__you { font-size: 12px; flex-shrink: 0; }
/* spec 096: the "Set a status" button at the end of the reader's own row */
.self-row__status {
  margin-inline-start: auto;
  flex-shrink: 0;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 28px;
  min-height: 28px;
  padding: 0;
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-muted);
  cursor: pointer;
}
.self-row__status:hover { color: var(--color-fg); background: var(--color-surface); }
/* spec 096 §5: name over the status note; the note is one truncated line */
.people-row__who { display: flex; flex-direction: column; min-width: 0; flex: 1 1 auto; }
.people-row__status { font-size: 0.75rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
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
/* spec 080 FR-005: the draft pencil leads the row's badge slot (079 unread) */
.draft-mark {
  margin-left: auto;
  display: inline-flex;
  align-items: center;
  color: var(--color-muted);
  flex-shrink: 0;
}
.draft-mark + .badge-mention,
.draft-mark + .badge-unread,
.draft-mark + .badge-total { margin-left: 4px; }
/* CLE-77873: a read DM's plain total - the unread pill's box, muted, no fill */
.badge-total {
  margin-left: auto;
  color: var(--color-muted);
  border-radius: var(--radius-pill);
  font-size: 0.6875rem;
  padding: 0 6px;
  min-width: 18px;
  text-align: center;
  flex-shrink: 0;
}
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
/* CLE-77851: a muted row is NOT faded. Opacity read as "inactive / not a
   member" (csitea #csi-fina), and on the row it also made the open row menu
   see-through. It keeps its look; RowMutedButton marks it and room is made
   for that bell before the row menu. */
.nav-row--muted > .nav-item { padding-inline-end: 72px; }
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
/* SPL-1134: the ONE channel under a dragged topic - filled when it may take
   it, "not allowed" (never filled) when it may not */
.nav-row--move-over { background: var(--color-selected); outline: 2px solid var(--focus-ring); outline-offset: -2px; border-radius: var(--radius-sm); }
.nav-row--move-denied { position: relative; opacity: 0.6; }
.nav-row--move-denied::after {
  content: attr(data-move-denied-label);
  position: absolute; inset-inline-end: 8px; top: 50%; transform: translateY(-50%);
  padding: 0 6px; border-radius: var(--radius-sm);
  background: var(--color-surface); color: var(--color-muted);
  font-size: 0.75rem; pointer-events: none;
}
.foot-row { display: flex; align-items: center; gap: 8px; padding: 8px 16px 4px; }
.foot-row .health { display: inline-flex; align-items: center; padding: 0 4px; }
/* owner 2026-09-27 (topic 86a570ea): on phones the connection is in the
   avatar sheet with the bell and the note - not on the start screen */
@media (max-width: 820px) {
  .foot-row .health { display: none; }
}
.foot-row .vs-wrap { flex: 0 1 auto; min-width: 0; display: flex; outline-offset: 2px; }
/* be316fdc: the clock at the version's size, right-aligned to the row's end
   (owner, t1 7b48293b: "right align to the end of the container"). Dot,
   bell + note, version and clock want ~246 px; the default 260 px sidebar's
   row has 212. With the clock the row's padding and gaps tighten, the
   version never shrinks under it, and on a mouse the bell and the note take
   the plain .icon-btn 32 px, not the 44 px tap target (touch keeps 44): 210 */
/* owner HUM-10, t1 57599bf2: the clock ~1 mm (4 px) off the drag bar, not
   flush. Desktop only by construction: phones host the clock in the strip. */
.foot-row:has(> .foot-row__clock) { gap: 6px; padding-inline: 12px 4px; }
.foot-row:has(> .foot-row__clock) .vs-wrap { flex: none; }
.foot-row:has(> .foot-row__clock) .version-stamp { padding-inline-start: 0; }
.foot-row .foot-row__clock { margin-inline-start: auto; font-size: calc(0.6875rem * 0.9); text-align: end; }
/* owner, t1 747c7e47: the version and the clock on ONE line, their lowest
   parts level. Both share one last-baseline group at the row's bottom, so
   their baselines meet; the bell, the note and the row height stay put. */
.foot-row .vs-wrap,
.foot-row .foot-row__clock { align-self: last baseline; }
@media not (pointer: coarse) {
  .foot-row:has(> .foot-row__clock) :deep(.notify-alerts),
  .foot-row:has(> .foot-row__clock) :deep(.notify-chime) { min-width: 32px; min-height: 32px; }
}
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
  /* SPL-999 (owner: "a bit bigger to fit the whole hash"): as wide as the
     hash + the copy button, never past the screen: fixed (the sidebar
     clips), just above the footer row, capped at the viewport minus 16 px */
  position: fixed;
  bottom: var(--vs-bottom, 48px);
  left: var(--vs-left, 8px);
  z-index: 30;
  display: flex;
  flex-direction: column;
  gap: 2px;
  box-sizing: border-box;
  width: max-content;
  max-width: calc(100vw - 16px);
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
.foot-row .vs-wrap:focus-within .vs-pop,
.foot-row .vs-wrap.is-open .vs-pop {
  visibility: visible;
  opacity: 1;
  transition-delay: 0s;
}
/* SPL-1023: hover opens it only where there is a real hover - a tap leaves
   :hover stuck on a touch screen, and the card would never close */
@media (hover: hover) {
  .foot-row .vs-wrap:hover .vs-pop {
    visibility: visible;
    opacity: 1;
    transition-delay: 0s;
  }
}
.foot-row .vs-pop__row { display: flex; align-items: center; gap: 6px; }
/* one line while it fits; on a narrow phone two even halves, never cut */
.foot-row .vs-pop__sha { min-width: 0; overflow-wrap: anywhere; word-break: break-all; text-wrap: balance; }
.foot-row .vs-pop__copy {
  display: inline-flex; align-items: center; justify-content: center; gap: 4px; flex: none;
  min-width: 28px; min-height: 28px; padding: 0 4px;
  font: inherit; font-family: var(--font-sans, inherit); font-size: 0.7rem;
  border: 1px solid transparent; border-radius: var(--radius-sm);
  background: transparent; color: var(--color-muted); cursor: pointer;
}
.foot-row .vs-pop__copy:hover,
.foot-row .vs-pop__copy:focus-visible { color: var(--color-fg); border-color: var(--color-border); }
@media (max-width: 820px) {
  .foot-row .vs-pop__copy { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
}
.foot-row .vs-pop__meta { color: var(--color-muted); overflow-wrap: anywhere; }
/* SPL-1006: a newer build is live than the one this tab runs */
.foot-row .vs-pop__newer { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; color: var(--color-warn); overflow-wrap: anywhere; }
/* SPL-1787: one row, powered-by at the start, Release notes at the end */
.foot-row .vs-pop__foot { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.foot-row .vs-pop__powered { color: var(--color-muted); }
.foot-row .vs-pop__reload { font: inherit; color: var(--color-accent); background: none; border: 0; padding: 0.25rem 0; text-decoration: underline; cursor: pointer; }
@media (pointer: coarse) { .foot-row .vs-pop__reload { min-height: 44px; } }
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
    /* SPL-2062 (owner HUM-10, t1 508e17a0): whole controls only. Each
       control is 1/fit of the strip (useLoopStrip writes data-fit from the
       width: as many as fit at 64 px, the extra width shared out), no gap
       and no side padding, and a swipe stops on a control's edge, so no
       control is ever cut at either end, the last one included. */
    padding-inline: 0;
    gap: 0;
    scroll-snap-type: x mandatory;
    container-type: inline-size;
    --strip-fit: 5;
    --strip-item: calc(100cqi / var(--strip-fit));
  }
  .sidebar-rail[data-fit="1"] { --strip-fit: 1; }
  .sidebar-rail[data-fit="2"] { --strip-fit: 2; }
  .sidebar-rail[data-fit="3"] { --strip-fit: 3; }
  .sidebar-rail[data-fit="4"] { --strip-fit: 4; }
  .sidebar-rail[data-fit="6"] { --strip-fit: 6; }
  .sidebar-rail[data-fit="7"] { --strip-fit: 7; }
  .sidebar-rail[data-fit="8"] { --strip-fit: 8; }
  .sidebar-rail[data-fit="9"] { --strip-fit: 9; }
  .sidebar-rail[data-fit="10"] { --strip-fit: 10; }
  .sidebar-rail[data-fit="11"] { --strip-fit: 11; }
  .sidebar-rail[data-fit="12"] { --strip-fit: 12; }
  .sidebar-tab,
  .sidebar-rail__help,
  .sidebar-rail__qto,
  .sidebar-rail__settings {
    flex: 0 0 auto;
    box-sizing: border-box;
    width: var(--strip-item);
    min-width: 0;
    max-width: none;
    scroll-snap-align: start;
  }
  .sidebar-tab {
    min-height: 52px;
    aspect-ratio: auto;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 2px;
    padding: 4px 2px;
    line-height: 1.15;
    container-type: normal;
  }
  .sidebar-tab :deep(svg) { width: 22px; height: 22px; }
  /* CLE-77886 (owner, msg cbab6075): "make the selected section a bit
     smaller - 1px around each side and more 3d and a bit darker and with
     bolder font". The copies of the endless strip mark theirs with data-on;
     Help, Docs and the gear are links, data-current (railLinkOn, SPL-2434:
     not router-link-active, which outlives their page on a phone). */
  .sidebar-tab[aria-selected="true"],
  .sidebar-tab[data-on="true"],
  .sidebar-rail__help[data-current="true"],
  .sidebar-rail__qto[data-current="true"],
  .sidebar-rail__settings[data-current="true"] {
    margin: 1px;
    /* 1px in on each side inside the same slot: the row's step stays one
       control wide, and the snap area is the whole slot */
    width: calc(var(--strip-item) - 2px);
    scroll-margin-inline: 1px;
    min-height: 50px;
    background: color-mix(in srgb, var(--color-surface-hover) 78%, #000);
    color: var(--color-fg);
    box-shadow:
      0 2px 4px rgb(0 0 0 / 0.35),
      inset 0 1px 0 rgb(255 255 255 / 0.14),
      inset 0 -2px 0 rgb(0 0 0 / 0.25);
  }
  .sidebar-tab[aria-selected="true"] :deep(svg),
  .sidebar-tab[data-on="true"] :deep(svg) { width: 20px; height: 20px; }
  .sidebar-tab__label { display: block; max-width: 100%; overflow: hidden; text-overflow: ellipsis; font-size: 0.6875rem; white-space: nowrap; }
  .sidebar-tab[aria-selected="true"] .sidebar-tab__label,
  .sidebar-tab[data-on="true"] .sidebar-tab__label { font-weight: 700; }
  /* the endless strip's copies: [before][real][after], one row, same gap */
  .sidebar-rail__loop { display: flex; flex: 0 0 auto; gap: inherit; }
  .sidebar-rail__loop[data-loop="before"] { order: -1; }
  .sidebar-rail__loop .sidebar-rail__help { margin-inline-start: 0; }
  /* a section's own page (CLE-77886): the strip alone, above the page */
  .sidebar.sidebar--strip { max-height: none; }
  .sidebar--strip .sidebar-body,
  .sidebar--strip .sidebar-foot,
  .sidebar--strip > :not(.sidebar-main) { display: none; }
  /* a sideways drag scrolls the strip; a long press still reorders */
  .sidebar-tab--movable { touch-action: pan-x; }
  /* the phone strip: the gear ends the row, a 44 px target */
  .sidebar-rail__help,
  .sidebar-rail__qto,
  .sidebar-rail__settings { margin-block-start: 0; min-height: 52px; aspect-ratio: auto; container-type: normal; }
  .sidebar-rail__help :deep(svg),
  .sidebar-rail__qto :deep(svg),
  .sidebar-rail__settings :deep(svg) { width: 22px; height: 22px; }
  .sidebar.sidebar--rail { width: 100%; max-width: 100%; }
  .sidebar-body { padding-top: 4px; }
  .nav-row > .nav-item { min-height: 48px; }
}
</style>
