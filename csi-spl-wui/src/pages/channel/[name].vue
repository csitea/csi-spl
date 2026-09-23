<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2>#{{ name }}</h2>
      <!-- what its creator said it is for (channels-v1 §5.1), else the generic
           line; the retention note is never dropped, it just moves along -->
      <span v-if="description" class="muted feed-header__about" :title="description" data-test="channel-description">{{ description }}</span>
      <span class="muted">{{ retention ? t('pages.channel.subtitle_retention', { retention }) : t('pages.channel.subtitle') }}</span>
    </header>
    <MessageFeed :label="t('pages.feed_label', { target: '#' + name })" />
  </div>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useSessionStore } from '~/stores/session'
import { useSpoolEvents } from '~/composables/useSpoolEvents'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useNotificationStore } from '~/stores/notification'
import { normalizeChannel } from '~/utils/notify.mjs'
import { retentionDays } from '~/utils/channel-feed.mjs'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useThreadStore } from '~/stores/thread'
import { omniboxParentTaskId, omniboxPlaceholderKey } from '~/utils/omnibox-thread.mjs'

const route = useRoute()
const channel = useChannelStore()
const thread = useThreadStore()
/* the task an Omnibox send hangs off: the open thread, or a new one */
const replyTo = computed(() => omniboxParentTaskId(thread))
const notes = useNotificationStore()
const events = useSpoolEvents()
const api = useSpoolApi()
const session = useSessionStore()
const name = computed(() => String(route.params.name || 'lobby'))
const { t } = useI18n({ useScope: 'global' })
const description = computed(() => String(channel.channels.find((c) => c.channel_id === name.value)?.description || ''))
const retention = computed(() => {
  const n = retentionDays(channel.channels.find((c) => c.channel_id === name.value) || { channel_id: name.value })
  return n ? t('sidebar.retention_days', { n }) : ''
})

/* a live row carries the hub cursor, so the next read= counts from here */
function markRead(n: string) {
  const row = channel.channels.find((c) => c.channel_id === n)
  if (row && row.last_cursor) notes.markChannelRead('ch:' + normalizeChannel(n), row)
  else notes.markRead('ch:' + normalizeChannel(n))
}

/* the shell reads (channels + roster) belong to the plugin's createShellBootstrap
   (once per app). This page only selects the open feed: mock hydrates immediately,
   live waits for a member session — same predicate as onSession. */
watch([name, () => session.state], async ([n, st]) => {
  if (!api.mock && String(st) !== 'in') return
  await channel.selectChannel(n)
  markRead(n)
}, { immediate: true })

onMounted(() => {
  events.start()
})

/* CLE-3433 / OA-38: while `?thread=` names a thread, the Omnibox writes into
   THAT thread. Without this, channel.sendLive's `task_id: parentTaskId ||
   newId()` minted a new task per send and the exchange scattered. */
async function onSend(text: string, files?: File[]) {
  await channel.send(text, replyTo.value || undefined, files)
}

/* 022: the Omnibox lives in the top bar and sends here while this page is on screen */
useOmniboxTarget({
  placeholder: () => (replyTo.value
    ? t(omniboxPlaceholderKey(replyTo.value))
    : t('search.placeholder_target', { target: '#' + name.value })),
  send: onSend,
})
</script>
