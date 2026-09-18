<template>
  <nav class="sidebar">
    <div class="sidebar-brand">
      <h1>Spool</h1>
      <ThemeToggle />
    </div>
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
      <span v-if="channel.unread[c.channel_id]" class="badge-unread">{{ channel.unread[c.channel_id] }}</span>
    </NuxtLink>
    <form v-if="api.mock" class="create-row" @submit.prevent="onCreate">
      <input v-model="newChannel" placeholder="new channel" aria-label="New channel">
      <button class="btn ghost" type="submit">+</button>
    </form>
    <h2>Direct messages</h2>
    <NuxtLink
      v-for="p in roster.peers"
      :key="p.label"
      class="nav-item"
      :class="{ active: channel.peer === p.label }"
      :to="'/dm/' + encodeURIComponent(p.label)"
    >
      <span class="dot" :class="{ on: p.online }" />
      <span class="label">{{ p.label }}</span>
    </NuxtLink>
    <div style="margin-top:auto">
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
import { useSpoolApi } from '~/composables/useSpoolApi'

const channel = useChannelStore()
const roster = useRosterStore()
const session = useSessionStore()
/* channel creation is a later M3 write slice; the live hub API is read-only */
const api = useSpoolApi()
const route = useRoute()
onMounted(() => session.probe())
const newChannel = ref('')
const config = useRuntimeConfig()
const version = computed(() => String(config.public.appVersion || 'v0.1.0-dev'))

async function onCreate() {
  const name = newChannel.value.trim()
  if (!name) return
  const row = await channel.createChannel(name)
  newChannel.value = ''
  await navigateTo('/channel/' + row.channel_id)
}
</script>
