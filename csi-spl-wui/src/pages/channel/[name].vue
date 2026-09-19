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
import { normalizeChannel } from '~/utils/notify.mjs'

const route = useRoute()
const channel = useChannelStore()
const roster = useRosterStore()
const notes = useNotificationStore()
const events = useSpoolEvents()
const name = computed(() => String(route.params.name || 'lobby'))

watch(name, async (n) => {
  await channel.selectChannel(n)
  notes.markRead('ch:' + normalizeChannel(n))
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
