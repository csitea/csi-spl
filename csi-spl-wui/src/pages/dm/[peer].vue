<template>
  <div class="feed-col" data-pane="msgs">
    <FeedHeader
      :title="peerName"
      :title-tip="peer"
      :status="presence.status"
      :status-text="headerStatus"
      :ring="peerManual?.ring || ''"
      status-shown
      :archived-at="openArchive.at"
      :topic-title="openArchive.title"
    />
    <!-- t1 3eb98913 (owner: "it dos not even have a msg button"): an empty DM
         offered nothing to click - its composer is the Omnibox. -->
    <div v-if="dmEmpty" class="dm-start">
      <button type="button" class="btn" data-test="dm-start-message" :title="peer" @click="focusComposer">
        <UiIcon name="messages" :size="16" /><span>{{ t('people.message') }}</span>
      </button>
    </div>
    <MessageFeed :label="t('pages.feed_label', { target: peer })" :boundary="feedBoundary" :seated-at="seatedAt" />
  </div>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import { useHumanNames } from '~/composables/useHumanNames'
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useRosterStore } from '~/stores/roster'
import { useHumanStatusStore } from '~/stores/human-status'
import { useTopicStore } from '~/stores/topic'
import { useSessionStore } from '~/stores/session'
import { useSpoolEvents } from '~/composables/useSpoolEvents'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useMobileStack } from '~/composables/useMobileStack'
import { useSidePane } from '~/composables/useSidePane'
import { isParentFlag, omniboxReplyTaskId, startsNewTopic } from '~/utils/omnibox-topic.mjs'
import { usePaneFocus } from '~/stores/pane-focus'
import { paneTakesLine } from '~/utils/pane-focus.mjs'
import { useTopicFeedClose } from '~/composables/useTopicRoute'
import { useNotificationStore } from '~/stores/notification'
import { dmPresence } from '~/utils/dm-presence.mjs'
import { BROWSER_BOX, topicTitleFromRows } from '~/utils/view-api.mjs'
import { archiveStamp } from '~/utils/topic-archive.mjs'
import { seatedAtFor } from '~/utils/seat-divider.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
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
const stack = useMobileStack()
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
/* CLE-77862 (HUM-24): the PEER's presence, in words beside the name - online,
   else when they were last seen (a member's last_seen, an agent's box hello),
   else "offline · queued". The reader's own dot is the sidebar's "you" row. */
const presence = computed(() => {
  const [id, box] = peer.value.split('@')
  const lastSeen = roster.humansDetail[String(id || '')]?.last_seen
    || (box && box !== BROWSER_BOX ? roster.boxes[box]?.last_hello_at : '')
  return dmPresence({ online: online.value, lastSeen: lastSeen || '' })
})

/* spec 096 §5: a peer's manual status replaces the presence words ("online",
   "last seen ...") in the header; the dot's fill still says presence */
const peerManual = computed(() => useHumanStatusStore().statusLabel(peer.value, t))
const headerStatus = computed(() => peerManual.value?.full || t(presence.value.key, presence.value.params))

/* Spec 061 3.6 (lane L10): when this agent id@box was seated by its current
   holder. A reused id's DM draws "new holder since" there; '' = none. */
const seatedAt = computed(() => {
  const [id, box] = peer.value.split('@')
  return seatedAtFor(roster.boxes, String(id || ''), String(box || ''))
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
/* CLE-77804: the read cursor this DM had when it was opened (frozen in the store
   by markRead), for the "New messages" divider (topic 1e7d56b8). */
const notes = useNotificationStore()
const feedBoundary = computed(() => notes.boundary['dm:' + peer.value] || null)
watch([peer, () => session.state], async ([p, st]) => {
  topicFeedReady.value = false
  if (!p) return
  if (!api.mock && String(st) !== 'in') return
  void import('~/utils/read-sync-boot').then((m) => m.startReadSync(api)) /* CLE-77930: reads follow the member across devices */
  notes.enterFeed('dm:' + p) /* freeze the divider boundary before the read */
  await channel.selectDm(p)
  if (peer.value !== p) return
  topicFeedReady.value = true
  releaseStaleTopic()
}, { immediate: true })

/* t1 404cd808 (owner: "it must be a clear indication in this view if
   somethign is archived"): the topic open on this DM (?topic=) - its archive
   stamp and title for the header's Archived mark. The hub stamps the first
   read of an archived topic (topic-archive.mjs archiveStamp); this page held
   no read of it, so one limit-1 read per opened topic. '' = live. */
const openArchive = ref({ at: '', title: '' })
const openTopicId = computed(() => (topic.open ? String(topic.parentTaskId || '') : ''))
watch(openTopicId, async (id) => {
  openArchive.value = { at: '', title: '' }
  if (!id) return
  try {
    const data = await withSessionRetry(api, () => api.getTopic(id, { limit: 1 })) as { messages?: SpoolMessage[] }
    if (openTopicId.value !== id) return
    const at = archiveStamp(data)
    openArchive.value = { at, title: at ? topicTitleFromRows(data.messages || [], topic.rootMsg) : '' }
  } catch {
    /* no mark is the live rendering; the topic pane reports a failed read */
  }
}, { immediate: true })

/* t1 3eb98913: no line yet in this DM, whatever the peer's kind (a-, c-, g-,
   m-, q- or a person) - Message puts the caret in the Omnibox, which already
   sends to this peer */
const dmEmpty = computed(() => topicFeedReady.value && !channel.loading && channel.messages.length === 0)
function focusComposer() {
  document.querySelector<HTMLTextAreaElement>('form.omnibox--global textarea')?.focus()
}

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
  /* the open topic takes the line, `@agent <text>` too (owner c3f0f2cf retired SPL-996 B) */
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
  placeholder: () => (stack.isMobile.value ? t(replyTarget() ? 'composer.phone_placeholder_reply' : 'composer.phone_placeholder_dm', { peer: peer.value }) : replyTarget() ? t(sk('topic.reply_placeholder')) : t(sk('search.placeholder_target'), { target: peer.value })),
  dock: () => ({ reply: Boolean(replyTarget()), target: peer.value, dm: true }),
  place: () => (replyTarget() ? `t:${replyTarget()}` : `dm:${peer.value}`),
  send: onSend,
})
</script>

<style scoped>
.dm-start { padding: 16px 16px 0; }
.dm-start .btn { display: inline-flex; align-items: center; gap: 6px; }
</style>
