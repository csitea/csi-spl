<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2>#{{ name }}</h2>
      <span class="muted">last 50 · tenant-scoped<template v-if="retention"> · {{ retention }} retention</template></span>
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
import { retentionLabel } from '~/utils/channel-feed.mjs'

const route = useRoute()
const channel = useChannelStore()
const roster = useRosterStore()
const notes = useNotificationStore()
const events = useSpoolEvents()
const name = computed(() => String(route.params.name || 'lobby'))
const retention = computed(() => retentionLabel(channel.channels.find((c) => c.channel_id === name.value) || { channel_id: name.value }))

/* a live row carries the hub cursor, so the next read= counts from here */
function markRead(n: string) {
  const row = channel.channels.find((c) => c.channel_id === n)
  if (row && row.last_cursor) notes.markChannelRead('ch:' + normalizeChannel(n), row)
  else notes.markRead('ch:' + normalizeChannel(n))
}

watch(name, async (n) => {
  await channel.selectChannel(n)
  markRead(n)
}, { immediate: true })

onMounted(async () => {
  events.start()
  await channel.loadChannels()
  await roster.refresh()
})

async function onSend(text: string) {
  await channel.send(text)
}
</script>
