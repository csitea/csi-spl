<template>
  <nav class="sidebar">
    <div class="sidebar-brand">
      <h1>Spool</h1>
      <ThemeToggle />
    </div>
    <NuxtLink class="nav-item" to="/lobby" active-class="active">
      <span class="hash">#</span><span class="label">lobby</span>
      <span v-if="notes.unread['ch:lobby']" class="badge-unread">{{ notes.previewUnread(notes.unread['ch:lobby']) }}</span>
    </NuxtLink>
    <NuxtLink class="nav-item" to="/" exact-active-class="active">
      <span class="label">Threads</span>
    </NuxtLink>
    <h2>Channels</h2>
    <NuxtLink
      v-for="c in channel.channels"
      :key="c.channel_id"
      class="nav-item"
      :class="{ active: channel.active === c.channel_id }"
      :to="'/channel/' + c.channel_id"
    >
      <span class="hash">#</span>
      <span class="label">{{ c.name }}</span>
      <span v-if="retentionLabel(c)" class="retention muted" :title="'messages kept ' + retentionLabel(c)">{{ retentionLabel(c) }}</span>
      <span v-if="notes.mentions['ch:' + c.channel_id]" class="badge-mention" data-testid="mention-count">@{{ notes.previewUnread(notes.mentions['ch:' + c.channel_id]) }}</span>
      <span v-if="notes.unread['ch:' + c.channel_id]" class="badge-unread">{{ notes.previewUnread(notes.unread['ch:' + c.channel_id]) }}</span>
    </NuxtLink>
    <form class="create-row" data-testid="create-channel" @submit.prevent="onCreate">
      <input v-model="newChannel" placeholder="new channel" aria-label="New channel" :disabled="creating">
      <button class="btn ghost" type="submit" :disabled="creating">+</button>
    </form>
    <p v-if="createError" class="muted create-error" role="alert">{{ createError }}</p>
    <h2>Direct messages</h2>
    <NuxtLink
      v-for="p in roster.peers"
      :key="p.label"
      class="nav-item"
      :class="{ active: channel.peer === p.label }"
      :to="'/dm/' + encodeURIComponent(p.label)"
    >
      <SpoolAvatar :id="p.id" :box="p.box" :size="22" />
      <span class="dot" :class="{ on: p.online }" />
      <span class="label">{{ p.label }}</span>
      <span v-if="notes.unread['dm:' + p.label]" class="badge-unread">{{ notes.previewUnread(notes.unread['dm:' + p.label]) }}</span>
    </NuxtLink>
    <div style="margin-top:auto">
      <div class="nav-item health" data-testid="connection-health" :title="'hub connection: ' + live.state.value">
        <span class="health-dot" :class="health" />
        <span class="label muted">{{ health === 'ok' ? 'connected' : health === 'warn' ? 'reconnecting…' : 'offline' }}</span>
      </div>
      <NotificationCenter />
      <div v-if="session.state === 'in'" class="nav-item">
        <span class="label">{{ session.label }}</span>
        <button class="btn ghost" type="button" @click="session.logout()">Sign out</button>
      </div>
      <NuxtLink v-else class="nav-item" :to="'/login?redirect=' + encodeURIComponent(route.fullPath)">
        <span class="label">Sign in</span>
      </NuxtLink>
      <p id="app-version" class="version-stamp">{{ version }}</p>
    </div>
  </nav>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { useNotificationStore } from '~/stores/notification'
import { useLive } from '~/composables/useLive'
import { connectionHealth, retentionLabel } from '~/utils/channel-feed.mjs'

const channel = useChannelStore()
const roster = useRosterStore()
const session = useSessionStore()
const notes = useNotificationStore()
const live = useLive()
const health = computed(() => connectionHealth(live.state.value))
const route = useRoute()
onMounted(() => session.probe())
const newChannel = ref('')
const creating = ref(false)
const createError = ref('')
const config = useRuntimeConfig()
const version = computed(() => String(config.public.appVersion || 'v0.1.0-dev'))

/** channels-v1 §5.1 errors, in words (409 channel_exists, 400 bad_channel). */
function createCopy(e: unknown) {
  const tok = (e && typeof e === 'object' && 'token' in e) ? String((e as { token?: unknown }).token || '') : ''
  if (tok === 'channel_exists') return 'That channel already exists (or the name is reserved).'
  if (tok === 'bad_channel') return 'Use lowercase letters, digits and dashes (max 64).'
  if (tok === 'view_door') return 'Sign in to create a channel.'
  return e instanceof Error ? e.message : 'channel not created'
}

async function onCreate() {
  const name = newChannel.value.trim()
  if (!name || creating.value) return
  creating.value = true
  createError.value = ''
  try {
    const row = await channel.createChannel(name)
    newChannel.value = ''
    await navigateTo('/channel/' + row.channel_id)
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
  border-radius: 999px;
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
