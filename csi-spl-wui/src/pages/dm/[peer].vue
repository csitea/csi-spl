<template>
  <div class="feed-col" data-pane="msgs">
    <header class="feed-header">
      <span class="dot" :class="{ on: online }" />
      <h2>{{ t('pane.msgs') }}</h2>
      <span class="muted">{{ peer }}</span>
      <span class="muted">{{ online ? t('pages.dm.online') : t('pages.dm.offline_queued') }}</span>
    </header>
    <MessageFeed :label="t('pages.feed_label', { target: peer })" />
  </div>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useRosterStore } from '~/stores/roster'
import { useTopicStore } from '~/stores/topic'
import { useSessionStore } from '~/stores/session'
import { useSpoolEvents } from '~/composables/useSpoolEvents'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useSidePane } from '~/composables/useSidePane'
import { omniboxReplyTaskId } from '~/utils/omnibox-topic.mjs'
import type { SpoolMessage } from '~/types/spool'

const route = useRoute()
const channel = useChannelStore()
const topic = useTopicStore()
const sidePane = useSidePane()
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

/* The line decides, unless the Topics list is the selected left pane and
   a topic is open: then the omnibox replies in that topic. `in: <title>`
   still names the topic. Any other left tab starts a new message. */
async function onSend(text: string, files?: File[], topicId?: string, channelId?: string) {
  const reply = omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: topic.open ? String(topic.parentTaskId || livePane.taskId || '') : String(livePane.taskId || ''),
    namedTopicId: topicId || '',
  })
  if (reply) topicId = reply
  const sent = await channel.send(text, topicId || undefined, files, channelId)
  topic.noteBorn(topic.open || Boolean(livePane.taskId), topicId, sent as SpoolMessage)
}

function replyTarget() {
  return omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: topic.open ? String(topic.parentTaskId || livePane.taskId || '') : String(livePane.taskId || ''),
    namedTopicId: '',
  })
}

/* 022: the Omnibox lives in the top bar and sends here while this page is on screen */
useOmniboxTarget({
  placeholder: () => (replyTarget() ? t('topic.reply_placeholder') : t('search.placeholder_target', { target: peer.value })),
  send: onSend,
})
</script>
