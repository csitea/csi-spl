<template>
  <div class="feed-col" data-pane="msgs">
    <header class="feed-header">
      <h2>{{ t('pane.msgs') }}</h2>
      <span class="muted">#{{ name }}</span>
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
import { useLiveFeed } from '~/stores/live'
import { useSessionStore } from '~/stores/session'
import { useTopicStore } from '~/stores/topic'
import { useSpoolEvents } from '~/composables/useSpoolEvents'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useNotificationStore } from '~/stores/notification'
import { normalizeChannel } from '~/utils/notify.mjs'
import { retentionDays } from '~/utils/channel-feed.mjs'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useSidePane } from '~/composables/useSidePane'
import { isParentFlag, omniboxReplyTaskId } from '~/utils/omnibox-topic.mjs'
import { usePaneFocus } from '~/stores/pane-focus'
import { paneTakesLine } from '~/utils/pane-focus.mjs'
import { useTopicFeedClose } from '~/composables/useTopicRoute'
import type { SpoolMessage } from '~/types/spool'

const route = useRoute()
const channel = useChannelStore()
const topic = useTopicStore()
const sidePane = useSidePane()
const livePane = useLiveFeed('pane')
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

/* Same close as the DM page: a channel change must not keep a topic that is
   not in this channel's messages. An empty list always closes. Ready stays
   false until selectChannel returns so the check sees this channel's list. */
const topicFeedReady = ref(false)
const { releaseStaleTopic } = useTopicFeedClose({
  ready: () => topicFeedReady.value,
  messages: () => channel.messages,
})

/* the shell reads (channels + roster) belong to the plugin's createShellBootstrap
   (once per app). This page only selects the open feed: mock hydrates immediately,
   live waits for a member session — same predicate as onSession. */
watch([name, () => session.state], async ([n, st]) => {
  topicFeedReady.value = false
  if (!api.mock && String(st) !== 'in') return
  await channel.selectChannel(n)
  markRead(n)
  if (name.value !== n) return
  topicFeedReady.value = true
  releaseStaleTopic()
}, { immediate: true })

onMounted(() => {
  events.start()
})

/* An open right pane takes the line. `in: <title>` still names a topic.
   A closed pane starts a new middle card. */
/* The open right pane takes the line only while it was the pane selected
   last; a click back in the middle makes the next line a new topic. */
const paneFocus = usePaneFocus()
function paneOpen() {
  return paneTakesLine({ paneOpen: Boolean(topic.open || livePane.taskId), lastPane: paneFocus.last })
}

function openTaskId() {
  return topic.open ? String(topic.parentTaskId || livePane.taskId || '') : String(livePane.taskId || '')
}

async function onSend(text: string, files?: File[], topicId?: string, channelId?: string) {
  const reply = omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: openTaskId(),
    namedTopicId: topicId || '',
    paneVisible: paneOpen(),
    lastPane: paneFocus.last,
  })
  if (reply) topicId = reply
  const sent = await channel.send(text, topicId || undefined, files, channelId, isParentFlag({ paneVisible: paneOpen() }))
  if (sent && sent.is_parent === 0 && livePane.taskId && (sent.task_id === livePane.taskId || sent.parent_task_id === livePane.taskId)) {
    livePane.admit([sent as SpoolMessage])
  }
  topic.noteBorn(topic.open || Boolean(livePane.taskId), topicId, sent as SpoolMessage)
}

function replyTarget() {
  return omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: openTaskId(),
    namedTopicId: '',
    paneVisible: paneOpen(),
    lastPane: paneFocus.last,
  })
}

/* 022: the Omnibox lives in the top bar and sends here while this page is on screen */
useOmniboxTarget({
  placeholder: () => (replyTarget() ? t('topic.reply_placeholder') : t('search.placeholder_target', { target: '#' + name.value })),
  send: onSend,
})
</script>
