<template>
  <nav class="sidebar">
    <h1>Spool</h1>
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
    <form class="create-row" @submit.prevent="onCreate">
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
      <NuxtLink class="nav-item" to="/login"><span class="label">Sign in</span></NuxtLink>
    </div>
  </nav>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'

const channel = useChannelStore()
const roster = useRosterStore()
const newChannel = ref('')

async function onCreate() {
  const name = newChannel.value.trim()
  if (!name) return
  const row = await channel.createChannel(name)
  newChannel.value = ''
  await navigateTo('/channel/' + row.channel_id)
}
</script>
