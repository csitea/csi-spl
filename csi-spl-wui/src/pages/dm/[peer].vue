<template>
  <div class="feed-col" data-pane="msgs">
    <FeedHeader
      :title="peerName"
      :title-tip="peer"
      :status="online ? 'on' : 'off'"
      :status-text="online ? t('pages.dm.online') : t('pages.dm.offline_queued')"
    />
    <MessageFeed :label="t('pages.feed_label', { target: peer })" />
  </div>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import { useHumanNames } from '~/composables/useHumanNames'
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useRosterStore } from '~/stores/roster'
import { useTopicStore } from '~/stores/topic'
import { useSessionStore } from '~/stores/session'
import { useSpoolEvents } from '~/composables/useSpoolEvents'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useSidePane } from '~/composables/useSidePane'
import { isParentFlag, omniboxReplyTaskId, startsNewTopic } from '~/utils/omnibox-topic.mjs'
import { usePaneFocus } from '~/stores/pane-focus'
import { paneTakesLine } from '~/utils/pane-focus.mjs'
import { useTopicFeedClose } from '~/composables/useTopicRoute'
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
/* SPL-976: the placeholder names the keys of the person's Behaviour setting */
const { hintFor: sk } = useSubmitKey()
const peer = computed(() => decodeURIComponent(String(route.params.peer || '')))
/* The person's chosen display name in the header; the URL keeps id@box. */
const people = useHumanNames()
const peerName = computed(() => {
  const [id, box] = peer.value.split('@')
  return people.label(String(id || ''), box || undefined)
})
const online = computed(() => {
  const [id, box] = peer.value.split('@')
  return roster.isOnline(id, box)
})

/* The topic pane reads one task and does not notice a peer change. Once this
   peer's messages have loaded, close that task when it is not one of them
   (an empty list always closes) and drop ?topic= / ?in= so a reload cannot
   reopen the previous person. Ready stays false until selectDm returns, so
   the check sees this peer's list. A card still opens through MessageFeed
   -> useTopicRoute.openRow -> topic.openTarget, and stays when that task is
   in the list. */
const topicFeedReady = ref(false)
const { releaseStaleTopic } = useTopicFeedClose({
  ready: () => topicFeedReady.value,
  messages: () => channel.messages,
})

/* the shell reads (channels + roster) belong to the plugin's createShellBootstrap
   (once per app). This page only selects the open DM: mock hydrates immediately,
   live waits for a member session — same predicate as onSession. */
watch([peer, () => session.state], async ([p, st]) => {
  topicFeedReady.value = false
  if (!p) return
  if (!api.mock && String(st) !== 'in') return
  await channel.selectDm(p)
  if (peer.value !== p) return
  topicFeedReady.value = true
  releaseStaleTopic()
}, { immediate: true })

/* read cursors follow channel.peer in plugins/notify.client.ts */
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
  /* SPL-996 B: the open topic takes the line; `@someone` first starts a new one */
  const fresh = startsNewTopic(text)
  const reply = omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: openTaskId(),
    namedTopicId: topicId || '',
    paneVisible: paneOpen(),
    lastPane: paneFocus.last,
    newTopic: fresh,
  })
  if (reply) topicId = reply
  const sent = await channel.send(text, topicId || undefined, files, channelId, isParentFlag({ paneVisible: paneOpen() && !fresh, replyTaskId: topicId || '' }))
  if (sent && sent.is_parent === 0 && livePane.taskId && (sent.task_id === livePane.taskId || sent.parent_task_id === livePane.taskId)) {
    livePane.admit([sent as SpoolMessage])
  }
  /* SPL-996: a new topic is its middle card and nothing else. It used to be
     drawn a second time at the top of the open right pane (BornTopics), which
     read as one message that is both an opening and a reply of that topic. */
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
  placeholder: () => (replyTarget() ? t(sk('topic.reply_placeholder')) : t(sk('search.placeholder_target'), { target: peer.value })),
  send: onSend,
})
</script>
