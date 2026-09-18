<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2>#{{ name }}</h2>
      <span class="muted">last 50 · tenant-scoped</span>
    </header>
    <MessageFeed />
    <MessageComposer @send="onSend" />
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
const notes = useNotificationStore()
const events = useSpoolEvents()
const name = computed(() => String(route.params.name || 'general'))

watch(name, async (n) => {
  await channel.selectChannel(n)
}, { immediate: true })

onMounted(async () => {
  await channel.loadChannels()
  await roster.refresh()
  events.start()
})

async function onSend(text: string) {
  const sent = await channel.send(text)
  if (sent && sent.kind === 'task') notes.ping('task sent', String(sent.body || ''))
}
</script>
