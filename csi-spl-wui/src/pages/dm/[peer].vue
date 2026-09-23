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
import { useLiveFeed } from '~/stores/live'
import { useRosterStore } from '~/stores/roster'
import { useThreadStore } from '~/stores/thread'
import { useSessionStore } from '~/stores/session'
import { useSpoolEvents } from '~/composables/useSpoolEvents'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useOmniboxTarget } from '~/stores/omnibox'
import type { SpoolMessage } from '~/types/spool'

const route = useRoute()
const channel = useChannelStore()
const thread = useThreadStore()
const livePane = useLiveFeed('pane')
const roster = useRosterStore()
const events = useSpoolEvents()
const api = useSpoolApi()
const session = useSessionStore()
const { t } = useI18n({ useScope: 'global' })
const peer = computed(() => decodeURIComponent(String(route.params.peer || '')))
const online = computed(() => {
  const [id, box] = peer.value.split('@')
  return roster.isOnline(id, box)
})

/* the shell reads (channels + roster) belong to the plugin's createShellBootstrap
   (once per app). This page only selects the open DM: mock hydrates immediately,
   live waits for a member session — same predicate as onSession. */
watch([peer, () => session.state], async ([p, st]) => {
  if (!p) return
  if (!api.mock && String(st) !== 'in') return
  await channel.selectDm(p)
}, { immediate: true })

/* read cursors follow channel.peer in plugins/notify.client.ts */
onMounted(() => {
  events.start()
})

/* The line decides. `@receiver` (and any line that does not name a thread)
   starts a new message here. `in: <title>` arrives as threadId and replies
   into that thread. While the right pane is open, a new message is another
   thread at the top of that pane. */
async function onSend(text: string, files?: File[], threadId?: string, channelId?: string) {
  const sent = await channel.send(text, threadId || undefined, files, channelId)
  thread.noteBorn(thread.open || Boolean(livePane.taskId), threadId, sent as SpoolMessage)
}

/* 022: the Omnibox lives in the top bar and sends here while this page is on screen */
useOmniboxTarget({
  placeholder: () => t('search.placeholder_target', { target: peer.value }),
  send: onSend,
})
</script>
