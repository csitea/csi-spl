<template>
  <nav class="sidebar">
    <!-- Top to bottom: direct messages, channels, threads, flow.
         Icons only; each name lives on aria-label and title. -->
    <div
      class="sidebar-rail"
      role="tablist"
      aria-orientation="vertical"
      :aria-label="railLabel"
    >
      <button
        v-for="item in RAIL"
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
    <h2>{{ t('sidebar.direct_messages') }}</h2>
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
      :title="t('auth.login.signed_in_as', { who: roster.self.label })"
    >
      <SpoolAvatar :id="roster.self.id" :box="roster.self.box" :size="22" />
      <span class="dot" :class="{ on: roster.self.online }" />
      <span class="label">{{ roster.self.label }}</span>
      <!-- `sidebar.you` carries its own brackets: a bracket hard-coded here
           lands on the wrong side of an RTL label (he), because the bidi
           algorithm resolves neutral punctuation from its surroundings. -->
      <span class="muted self-row__you">{{ t('sidebar.you') }}</span>
    </div>
    <NuxtLink
      v-for="p in peers"
      :key="p.label"
      class="nav-item"
      :class="{ active: channel.peer === p.label }"
      :data-key="p.label"
      :data-ts="channel.dmAt[p.label] || undefined"
      :to="localePath('/dm/' + encodeURIComponent(p.label))"
    >
      <SpoolAvatar :id="p.id" :box="p.box" :size="22" />
      <span class="dot" :class="{ on: p.online }" />
      <span class="label">{{ p.label }}</span>
      <span v-if="notes.unread['dm:' + p.label]" class="badge-unread">{{ notes.previewUnread(notes.unread['dm:' + p.label]) }}</span>
    </NuxtLink>
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
      <h2>{{ t('sidebar.channels') }}</h2>
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
    <NuxtLink
      v-for="c in channel.ordered"
      :key="c.channel_id"
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
        v-show="tab === 'threads'"
        id="sidebar-panel-threads"
        class="sidebar-panel"
        role="tabpanel"
        aria-labelledby="sidebar-tab-threads"
        data-testid="sidebar-panel-threads"
      >
        <h2>{{ t('nav.threads') }}</h2>
        <p v-if="!viewer.loading && viewer.threads.length === 0" class="muted thread-empty">{{ t('pages.index.empty') }}</p>
        <a
          v-for="row in viewer.threads"
          :key="row.task_id"
          class="nav-item"
          :class="{ active: threadOpen === row.task_id }"
          :data-key="row.task_id"
          :data-ts="row.last_ts || undefined"
          :href="localePath('/t/' + row.task_id)"
          @click.exact.prevent="pane.open(row.task_id)"
        >
          <span class="label">{{ row.subject || row.participants.join(', ') || row.task_id }}</span>
        </a>
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
        <p v-if="flow.length === 0" class="muted thread-empty">{{ t('feed.empty') }}</p>
        <template v-for="row in flow" :key="row.key">
          <NuxtLink
            v-if="row.kind === 'channel'"
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
          <NuxtLink
            v-else-if="row.kind === 'dm'"
            class="nav-item"
            :class="{ active: channel.peer === row.label }"
            :data-key="row.label"
            :data-kind="row.kind"
            :data-ts="row.at || undefined"
            :to="localePath('/dm/' + encodeURIComponent(row.label))"
          >
            <SpoolAvatar :id="row.id" :box="row.box" :size="22" />
            <span class="dot" :class="{ on: row.online }" />
            <span class="label">{{ row.label }}</span>
            <span v-if="notes.unread['dm:' + row.label]" class="badge-unread">{{ notes.previewUnread(notes.unread['dm:' + row.label]) }}</span>
          </NuxtLink>
          <a
            v-else
            class="nav-item"
            :class="{ active: threadOpen === row.id }"
            :data-key="row.id"
            :data-kind="row.kind"
            :data-ts="row.at || undefined"
            :href="localePath('/t/' + row.id)"
            @click.exact.prevent="pane.open(row.id)"
          >
            <span class="label">{{ row.label }}</span>
          </a>
        </template>
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
  </nav>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useRosterStore } from '~/stores/roster'
import { useViewerStore } from '~/stores/viewer'
import { useSessionStore } from '~/stores/session'
import { useAccessStore } from '~/stores/access'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { isSignedOutVisitor } from '~/utils/shell-bootstrap.mjs'
import { useNotificationStore } from '~/stores/notification'
import { useLive } from '~/composables/useLive'
import { channelActivity, channelSlug, connectionHealth, orderPeers, retentionDays } from '~/utils/channel-feed.mjs'
import { buildStampText, buildStampTitle, readBuildStamp } from '~/utils/build-stamp.mjs'
import { useSidePane } from '~/composables/useSidePane'
import { flowRows, SIDE_TABS, tabForPath } from '~/utils/sidebar-tabs.mjs'
import type { UiIconName } from '~/utils/uiIcons'

type SideTab = 'dm' | 'channels' | 'threads' | 'flow'
/* Direct messages, channels, threads, flow — top to bottom. A matching
   route follows the page; search and settings keep the reader's choice. */
const RAIL: { id: SideTab, icon: UiIconName, labelKey: string }[] = [
  { id: 'dm', icon: 'messages', labelKey: 'sidebar.direct_messages' },
  { id: 'channels', icon: 'hash', labelKey: 'sidebar.channels' },
  { id: 'threads', icon: 'list', labelKey: 'nav.threads' },
  { id: 'flow', icon: 'waves', labelKey: 'sidebar.flow' },
]
const tab = ref<SideTab>('dm')
/* The flow list stays up while a row from it is opened. Another icon clears it. */
const holdFlow = ref(false)
const route = useRoute()
watch(() => route.path, (path) => {
  if (holdFlow.value) return
  const next = tabForPath(path)
  if (next) tab.value = next
}, { immediate: true })
function onTabKey(e: KeyboardEvent) {
  const order = SIDE_TABS as readonly SideTab[]
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
const roster = useRosterStore()
const session = useSessionStore()
const access = useAccessStore()
const api = useSpoolApi()
const signedOut = computed(() => isSignedOutVisitor(session.state, api.mock))
const notes = useNotificationStore()
const live = useLive()
const { t, te } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const railLabel = computed(() => RAIL.map((item) => t(item.labelKey)).join(', '))
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
const threadOpen = computed(() => {
  if (pane.taskId) return pane.taskId
  const m = route.path.match(/\/t\/([^/]+)$/)
  return m ? decodeURIComponent(m[1]) : ''
})
/* Threads opens the thread index. Flow stays on this page and mixes the
   three lists. Direct messages and channels only swap the sidebar. */
async function selectTab(next: SideTab) {
  holdFlow.value = next === 'flow'
  tab.value = next
  if (next === 'threads') {
    if (viewer.threads.length === 0) void viewer.loadThreads()
    if (tabForPath(route.path) !== 'threads') await navigateTo(localePath('/'))
    return
  }
  if (next === 'flow' && viewer.threads.length === 0) void viewer.loadThreads()
}
const sidePane = useSidePane()
watch(() => sidePane.requested.value, (req) => {
  if (req) void selectTab(req.id)
})
watch(tab, (id) => {
  if ((id === 'threads' || id === 'flow') && viewer.threads.length === 0) void viewer.loadThreads()
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
const peers = computed(() => orderPeers(roster.peers, channel.dmAt))
const flow = computed(() => flowRows({
  channels: channel.ordered,
  peers: peers.value,
  threads: viewer.threads,
  liveAt: channel.liveAt,
  dmAt: channel.dmAt,
}))
onMounted(() => session.probe())
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
.thread-empty { padding: 8px 16px; margin: 0; }
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
</style>
