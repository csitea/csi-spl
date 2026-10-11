<!-- /t/<task_id>: one topic on its own page, the thread alone. Every copied
     link and a topic with no channel and no DM open here (open-message.mjs).
     Owner HUM-10 (t1 e4bfddb1, msg a78e06c8: "Remove the whole topics
     view"): the Topics list that sat beside the thread is gone; the shell's
     left panel (Channels) is beside it instead. -->
<template>
  <div
    class="topic-browse"
    data-test="topic-browse"
    :data-phone="stack.isMobile.value ? 'thread' : undefined"
  >
    <div class="topic-browse__thread" data-test="topic-browse-thread">
      <TopicPane />
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import { useChannelStore } from '~/stores/channel'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useTopicStore } from '~/stores/topic'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useMobileStack } from '~/composables/useMobileStack'
import { useSidePane } from '~/composables/useSidePane'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { isParentFlag, omniboxReplyTaskId, startsNewTopic } from '~/utils/omnibox-topic.mjs'
import { openingCardId } from '~/utils/topic-archive.mjs'
import { dmPeerOf } from '~/utils/channel-feed.mjs'
import type { SpoolMessage } from '~/types/spool'

const route = useRoute()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
const { hintFor: sk } = useSubmitKey()
const api = useSpoolApi()
const channel = useChannelStore()
const topic = useTopicStore()
const sidePane = useSidePane()
const stack = useMobileStack()
const editor = useMessageEdit()

const taskId = computed(() => String(route.params.task_id || ''))
const shortId = computed(() => taskId.value.slice(0, 8))
const sending = ref(false)

/* a phone: the thread is the right panel (level 3); Back leaves the page */
stack.rightPanel(() => stack.isMobile.value && topic.open, () => topic.close())
/* the thread's X: with no list beside it, the page has nothing left to
   show, so it goes to the front door (Channels) */
watch(() => topic.open, (open, was) => {
  if (was && !open && taskId.value) void navigateTo(localePath('/'), { replace: true })
})

function openingOf(rows: SpoolMessage[], id: string): SpoolMessage | null {
  const mine = rows.filter((m) => String(m.parent_task_id || m.task_id || '') === id)
  /* A channel card is the topic root. A desc thread page lists replies first,
     and a reply with no is_parent still counts as a card, so take the root
     and read it oldest-first before openingCardId. */
  const roots = mine.filter((m) => !String(m.parent_task_id || '') && String(m.task_id || '') === id)
  const pool = (roots.length ? roots : mine).slice().sort((a, b) => String(a.ts || '').localeCompare(String(b.ts || '')))
  const found = openingCardId(pool, '')
  if (!found) return null
  return pool.find((m) => String(m.msg_id || '') === found) || null
}

/** The same card a channel feed would draw for this topic. */
async function cardOf(id: string): Promise<SpoolMessage | null> {
  const local = openingOf(channel.messages, id)
  if (local) return local
  try {
    const page = await api.getTopic(id, { limit: 30 }) as { messages?: SpoolMessage[] }
    return openingOf(page.messages || [], id)
  } catch {
    return null
  }
}

/* TopicPane's mock path reads the channel store, not its own fetch.
   Seed that store from the same read before opening, or the thread is empty. */
async function seedMockThread(id: string) {
  if (!api.mock) return
  const data = await api.getTopic(id, { order: 'desc', limit: 50 }) as { messages?: { msg_id?: string }[] }
  const rows = data.messages || []
  const have = new Set(channel.messages.map((m) => String(m.msg_id || '')))
  const add = rows.filter((m) => m && m.msg_id && !have.has(String(m.msg_id)))
  if (add.length) channel.messages = [...channel.messages, ...(add as typeof channel.messages)]
}

async function showTopic(id: string) {
  await seedMockThread(id)
  if (taskId.value !== id) return
  topic.openTopic(id)
}

/* spec 117 FR-4 (t1 f87e6c9d): this page holds no DM peer, so a reply in a
   person-to-person DM topic went out with no `to`, and the hub stored it as
   ALL-0 that only its sender could read. A topic with no channel and exactly
   one other end sends to that end, as /dm/<peer> does. */
async function dmPeerOfTopic(id: string): Promise<string> {
  const root = await cardOf(id)
  return root && !root.channel ? dmPeerOf(root, String(editor.viewerId.value || '')) : ''
}

async function onSend(text: string, files?: File[], topicId?: string, channelId?: string) {
  const fresh = startsNewTopic(text)
  const visible = topic.open
  const target = omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: taskId.value,
    namedTopicId: topicId || '',
    paneVisible: visible,
    newTopic: fresh,
  })
  sending.value = true
  try {
    await channel.send(
      text,
      target || undefined,
      files,
      channelId,
      isParentFlag({ paneVisible: visible && !fresh, replyTaskId: target || '' }),
      target && !channelId && !channel.peer ? await dmPeerOfTopic(target) : undefined,
    )
  } finally {
    sending.value = false
  }
}

function replyTarget() {
  return omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: taskId.value,
    namedTopicId: '',
    paneVisible: topic.open,
  })
}

useOmniboxTarget({
  placeholder: () => (stack.isMobile.value ? (replyTarget() ? t('composer.phone_placeholder_reply') : channel.peer ? t('composer.phone_placeholder_dm', { peer: channel.peer }) : t('composer.phone_placeholder_channel', { name: channel.active || shortId.value })) : replyTarget() ? t(sk('topic.reply_placeholder')) : t(sk('search.placeholder_target'), { target: shortId.value })),
  dock: () => ({ reply: Boolean(replyTarget()), target: shortId.value }),
  place: () => (replyTarget() ? `t:${replyTarget()}` : channel.peer ? `dm:${channel.peer}` : `ch:${channel.active || ''}`),
  send: onSend,
  busy: () => sending.value,
})

if (import.meta.client) {
  watch(taskId, async (id) => {
    if (id) await showTopic(id)
  }, { immediate: true })
}

onUnmounted(() => {
  /* Closing while the next page still names a topic strips its ?topic=
     (the channel page writes the store back onto its own URL). A page
     with no topic query does not want this pane left open. */
  const cur = useRouter().currentRoute.value
  const path = String(cur.path || '')
  if (/\/t\/[^/]+$/.test(path)) return
  if (cur.query.topic || cur.query.in) return
  topic.close()
})
</script>
