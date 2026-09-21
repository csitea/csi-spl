<template>
  <nav class="sidebar">
    <NuxtLink class="nav-item" :to="localePath('/lobby')" active-class="active">
      <span class="hash">#</span><span class="label">lobby</span>
      <span v-if="notes.unread['ch:lobby']" class="badge-unread">{{ notes.previewUnread(notes.unread['ch:lobby']) }}</span>
    </NuxtLink>
    <NuxtLink class="nav-item" :to="localePath('/')" exact-active-class="active">
      <span class="label">{{ t('nav.threads') }}</span>
    </NuxtLink>
    <h2>{{ t('sidebar.channels') }}</h2>
    <NuxtLink
      v-for="c in channel.ordered"
      :key="c.channel_id"
      class="nav-item"
      :class="{ active: channel.active === c.channel_id }"
      :data-key="c.channel_id"
      :data-ts="channelActivity(c, channel.liveAt) || undefined"
      :to="localePath('/channel/' + c.channel_id)"
    >
      <span class="hash">#</span>
      <span class="label">{{ c.name }}</span>
      <span v-if="retentionLabel(c)" class="retention muted" :title="t('sidebar.retention_title', { retention: retentionLabel(c) })">{{ retentionLabel(c) }}</span>
      <span v-if="notes.mentions['ch:' + c.channel_id]" class="badge-mention" data-testid="mention-count">@{{ notes.previewUnread(notes.mentions['ch:' + c.channel_id]) }}</span>
      <span v-if="notes.unread['ch:' + c.channel_id]" class="badge-unread">{{ notes.previewUnread(notes.unread['ch:' + c.channel_id]) }}</span>
    </NuxtLink>
    <!-- CLE-3433: `access.can` fails OPEN by design (the store only hides
         actions; the hub re-checks every write), which is right for a member
         whose /view/me read failed and wrong for a visitor who is not signed
         in at all - they were offered a live "new channel" field that can
         only answer 401. A settled signed-out probe is not a failed read. -->
    <form v-if="!signedOut && access.can('channels.manage')" class="create-row" data-testid="create-channel" @submit.prevent="onCreate">
      <input v-model="newChannel" :placeholder="t('sidebar.new_channel_placeholder')" :aria-label="t('sidebar.new_channel_label')" :disabled="creating">
      <button class="btn ghost" type="submit" :disabled="creating">+</button>
    </form>
    <p v-if="createError" class="muted create-error" role="alert">{{ createError }}</p>
    <h2>{{ t('sidebar.direct_messages') }}</h2>
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
    <div style="margin-top:auto">
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
  </nav>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { useAccessStore } from '~/stores/access'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { isSignedOutVisitor } from '~/utils/shell-bootstrap.mjs'
import { useNotificationStore } from '~/stores/notification'
import { useLive } from '~/composables/useLive'
import { channelActivity, connectionHealth, orderPeers, retentionDays } from '~/utils/channel-feed.mjs'
import { buildStampText, buildStampTitle, readBuildStamp } from '~/utils/build-stamp.mjs'

const channel = useChannelStore()
const roster = useRosterStore()
const session = useSessionStore()
const access = useAccessStore()
const api = useSpoolApi()
const signedOut = computed(() => isSignedOutVisitor(session.state, api.mock))
const notes = useNotificationStore()
const live = useLive()
const { t, te } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
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
onMounted(() => session.probe())
/* specs/025 FR-008: the role decides which actions are offered (the hub re-checks). */
watch(() => session.state, (st) => { if (st === 'in') access.load() }, { immediate: true })
const newChannel = ref('')
const creating = ref(false)
const createError = ref('')
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
    const row = await channel.createChannel(name)
    newChannel.value = ''
    await navigateTo(localePath('/channel/' + row.channel_id))
  } catch (e) {
    createError.value = createCopy(e)
  } finally {
    creating.value = false
  }
}
</script>

<style scoped>
.retention { font-size: 11px; flex-shrink: 0; }
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
.create-error { padding: 0 16px; font-size: 12px; overflow-wrap: anywhere; }
.health-dot {
  width: 8px; height: 8px; border-radius: 50%;
  background: var(--color-danger);
  flex-shrink: 0;
}
.health-dot.ok { background: var(--color-ok); }
.health-dot.warn { background: var(--color-muted); }
</style>
