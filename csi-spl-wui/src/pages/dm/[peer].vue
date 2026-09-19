<template>
  <div class="feed-col">
    <header class="feed-header">
      <span class="dot" :class="{ on: online }" />
      <h2>{{ peer }}</h2>
      <span class="muted">{{ online ? 'online' : 'offline · queued' }}</span>
    </header>
    <MessageFeed />
    <MessageComposer :placeholder="'Message ' + peer" @send="onSend" />
  </div>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import { useSpoolEvents } from '~/composables/useSpoolEvents'
import { useNotificationStore } from '~/stores/notification'

const route = useRoute()
const channel = useChannelStore()
const roster = useRosterStore()
const events = useSpoolEvents()
const notes = useNotificationStore()
const peer = computed(() => decodeURIComponent(String(route.params.peer || '')))
const online = computed(() => {
  const [id, box] = peer.value.split('@')
  return roster.isOnline(id, box)
})

watch(peer, async (p) => {
  if (p) {
    await channel.selectDm(p)
    notes.markRead('dm:' + p)
  }
}, { immediate: true })

onMounted(async () => {
  await channel.loadChannels()
  await roster.refresh()
  events.start()
})

async function onSend(text: string) {
  await channel.send(text)
}
</script>
