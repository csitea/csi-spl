<template>
  <div class="feed-col" data-pane="msgs">
    <FeedHeader :title="'#' + titleName" />
    <MessageFeed :label="t('pages.feed_label', { target: '#' + name })" />
  </div>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useSessionStore } from '~/stores/session'
import { useTopicStore } from '~/stores/topic'
import { useSpoolEvents } from '~/composables/useSpoolEvents'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useNotificationStore } from '~/stores/notification'
import { normalizeChannel } from '~/utils/notify.mjs'
import { feedbackChannelCopy } from '~/utils/feedback-channel.mjs'
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
/* SPL-976: the placeholder names the keys of the person's Behaviour setting */
const { hintFor: sk } = useSubmitKey()
const storedDescription = computed(() => String(channel.channels.find((c) => c.channel_id === name.value)?.description || ''))
const feedbackCopy = computed(() => feedbackChannelCopy(name.value, {
  name: t('channels.feedback.name'),
  description: t('channels.feedback.description'),
}, storedDescription.value))
const titleName = computed(() => feedbackCopy.value ? feedbackCopy.value.name : name.value)

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
  placeholder: () => (replyTarget() ? t(sk('topic.reply_placeholder')) : t(sk('search.placeholder_target'), { target: '#' + name.value })),
  send: onSend,
})
</script>
