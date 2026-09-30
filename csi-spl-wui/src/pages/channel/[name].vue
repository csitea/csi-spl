<template>
  <div class="feed-col" data-pane="msgs">
    <FeedHeader :title="'#' + titleName" />
    <MessageFeed :label="t('pages.feed_label', { target: '#' + name })" :boundary="feedBoundary" />
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
import { isParentFlag, omniboxReplyTaskId, startsNewTopic } from '~/utils/omnibox-topic.mjs'
import { usePaneFocus } from '~/stores/pane-focus'
import { paneTakesLine } from '~/utils/pane-focus.mjs'
import { useTopicFeedClose } from '~/composables/useTopicRoute'
import type { SpoolMessage } from '~/types/spool'
import { withSessionRetry } from '~/utils/live-follow.mjs'

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

/* CLE-77804 (topic 1e7d56b8): the read cursor this channel had when it was
   opened (frozen in the store by markRead, so no snapshot can race it), for the
   "New messages" divider at the first message the reader had not seen. */
const feedBoundary = computed(() => notes.boundary['ch:' + normalizeChannel(name.value)] || null)

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
  notes.enterFeed('ch:' + normalizeChannel(n)) /* freeze the divider boundary before markRead */
  await channel.selectChannel(n)
  markRead(n)
  if (name.value !== n) return
  if (await redirectMoved(n)) return
  topicFeedReady.value = true
  releaseStaleTopic()
}, { immediate: true })

onMounted(() => {
  events.start()
})

/*
 * SPL-1024 (specs/045 §3.1): a link to the OLD channel of a moved topic
 * (/channel/<old>?topic=<task>, ?thread=, ?in=) is sent on to the channel the
 * topic is in now, the query kept - a redirect, not an empty pane. Asked only
 * when this channel's feed does not hold the task, so an ordinary deep link
 * costs no extra read.
 */
const router = useRouter()
const localePath = useLocalePath()
async function redirectMoved(n: string): Promise<boolean> {
  const q = route.query
  if (!q.topic && !q.thread && !q.in) return false
  const { movedChannelFor, queryTasks } = await import('~/utils/move-apply.mjs')
  const tasks = queryTasks(q)
  if (tasks.some((id) => channel.messages.some((m) => m.task_id === id || m.msg_id === id))) return false
  for (const id of tasks) {
    let rows: SpoolMessage[] = []
    try {
      rows = (await withSessionRetry(api, () => api.getTopic(id, { order: 'desc', limit: 1 }))).messages || []
    } catch {
      return false
    }
    if (!rows.length) continue
    const to = movedChannelFor(rows, n)
    if (!to || name.value !== n) return false
    await router.replace({ path: localePath('/channel/' + to), query: route.query })
    return true
  }
  return false
}

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
  placeholder: () => (replyTarget() ? t(sk('topic.reply_placeholder')) : t(sk('search.placeholder_target'), { target: '#' + name.value })),
  dock: () => ({ reply: Boolean(replyTarget()), target: '#' + titleName.value }),
  send: onSend,
})
</script>
