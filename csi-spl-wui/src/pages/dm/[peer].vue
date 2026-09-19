<template>
  <div class="feed-col">
    <header class="feed-header">
      <span class="dot" :class="{ on: online }" />
      <h2>{{ peer }}</h2>
      <span class="muted">{{ online ? t('pages.dm.online') : t('pages.dm.offline_queued') }}</span>
    </header>
    <MessageFeed :label="t('pages.feed_label', { target: peer })" />
  </div>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useRosterStore } from '~/stores/roster'
import { useSpoolEvents } from '~/composables/useSpoolEvents'
import { useOmniboxTarget } from '~/stores/omnibox'

const route = useRoute()
const channel = useChannelStore()
const roster = useRosterStore()
const events = useSpoolEvents()
const { t } = useI18n({ useScope: 'global' })
const peer = computed(() => decodeURIComponent(String(route.params.peer || '')))
const online = computed(() => {
  const [id, box] = peer.value.split('@')
  return roster.isOnline(id, box)
})

watch(peer, async (p) => {
  if (p) {
    await channel.selectDm(p)
  }
}, { immediate: true })

/* read cursors follow channel.peer in plugins/notify.client.ts */
onMounted(async () => {
  events.start()
  await channel.loadChannels()
  await roster.refresh()
})

async function onSend(text: string) {
  await channel.send(text)
}

/* 022: the Omnibox lives in the top bar and sends here while this page is on screen */
useOmniboxTarget({
  placeholder: () => t('search.placeholder_target', { target: peer.value }),
  send: onSend,
})
</script>
