<template>
  <div
    class="topic-browse"
    data-test="topic-browse"
    :data-phone="stack.isMobile.value ? (phoneThread ? 'thread' : 'list') : undefined"
  >
    <section class="topic-browse__list" data-test="topic-browse-list" :aria-label="t('nav.topics')">
      <header class="feed-header">
        <MobileBack />
        <h2>{{ t('nav.topics') }}</h2>
        <span class="muted">{{ t('pages.index.subtitle') }}</span>
      </header>
      <div ref="listBody" class="feed-body">
        <ViewTokenForm v-if="viewer.needsToken" :detail="viewer.doorDetail" @saved="onDoor" />
        <ErrorNotice v-if="viewer.error" :message="viewer.error" source="viewer" test-id="viewer-error" />
        <p v-else-if="!viewer.needsToken && !viewer.loading && !viewer.error && viewer.topics.length === 0" class="muted">
          {{ t('pages.index.empty') }}
        </p>
        <template v-for="row in viewer.topics" :key="row.task_id">
        <a
          class="topic-row"
          :class="{ selected: taskId === row.task_id, 'is-archived': row.archived_at }"
          :aria-current="taskId === row.task_id ? 'true' : undefined"
          :data-key="row.task_id"
          :href="localePath('/t/' + row.task_id)"
          @click.exact.prevent="pick(row.task_id)"
        >
          <div class="topic-subject">{{ rowTitle(row.subject) }}</div>
          <ArchivedBadge v-if="row.archived_at" :at="row.archived_at" />
          <small class="muted">{{ t('pages.index.messages', { n: row.count }, row.count) }}</small>
        </a>
        </template>
        <button v-if="viewer.next" class="btn ghost" type="button" @click="viewer.loadMore()">{{ t('pages.index.older') }}</button>
      </div>
    </section>
    <div class="topic-browse__thread" data-test="topic-browse-thread">
      <TopicPane />
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useChannelStore } from '~/stores/channel'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useTopicStore } from '~/stores/topic'
import { useViewerStore } from '~/stores/viewer'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useMobileStack } from '~/composables/useMobileStack'
import { useSidePane } from '~/composables/useSidePane'
import { bumpTopic } from '~/utils/topic-list.mjs'
import { shouldOpenHubSocket } from '~/utils/shell-bootstrap.mjs'
import { isParentFlag, omniboxReplyTaskId, startsNewTopic } from '~/utils/omnibox-topic.mjs'
import { topicOpening } from '~/utils/view-api.mjs'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'

const route = useRoute()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
const { hintFor: sk } = useSubmitKey()
const api = useSpoolApi()
const session = useSessionStore()
const channel = useChannelStore()
const topic = useTopicStore()
const viewer = useViewerStore()
const sidePane = useSidePane()
const stack = useMobileStack()

const taskId = computed(() => String(route.params.task_id || ''))
const shortId = computed(() => taskId.value.slice(0, 8))
/* A deep link opens on the thread. Back (and the thread's X) returns to the list. */
const phoneThread = ref(true)
const listBody = ref<HTMLElement | null>(null)
const sending = ref(false)

stack.rightPanel(
  () => stack.isMobile.value && phoneThread.value && topic.open,
  () => { phoneThread.value = false },
)

/* The thread's X closes the topic store. On a phone that must reveal the list,
   or the thread column stays the one on screen and is empty. */
watch(() => topic.open, (open, was) => {
  if (was && !open) phoneThread.value = false
})

watch(() => viewer.needsToken, (need) => {
  if (!need) return
  phoneThread.value = false
  topic.close()
})

function rowTitle(subject: string) {
  return topicOpening(subject) || t('topic.title')
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
  if (taskId.value !== id || viewer.needsToken) {
    if (viewer.needsToken) {
      phoneThread.value = false
      topic.close()
    }
    return
  }
  topic.openTopic(id)
}

function pick(id: string) {
  if (viewer.needsToken) return
  phoneThread.value = true
  if (id !== taskId.value) {
    void navigateTo(localePath('/t/' + id))
    return
  }
  if (!topic.open) void showTopic(id)
}

async function onDoor() {
  await viewer.loadTopics()
  const id = taskId.value
  if (!id || viewer.needsToken) return
  phoneThread.value = true
  await showTopic(id)
}

/* The list is showing: the thread is not the line, even if the store is still open. */
function paneVisible() {
  if (stack.isMobile.value && !phoneThread.value) return false
  return topic.open
}

async function onSend(text: string, files?: File[], topicId?: string, channelId?: string) {
  const fresh = startsNewTopic(text)
  const visible = paneVisible()
  const target = omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: taskId.value,
    namedTopicId: topicId || '',
    paneVisible: visible,
    newTopic: fresh,
  })
  sending.value = true
  try {
    const sent = await channel.send(
      text,
      target || undefined,
      files,
      channelId,
      isParentFlag({ paneVisible: visible && !fresh, replyTaskId: target || '' }),
    )
    if (sent) viewer.topics = bumpTopic(viewer.topics, sent as unknown as Record<string, unknown>) as typeof viewer.topics
  } finally {
    sending.value = false
  }
}

function replyTarget() {
  return omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: taskId.value,
    namedTopicId: '',
    paneVisible: paneVisible(),
  })
}

useOmniboxTarget({
  placeholder: () => (replyTarget() ? t(sk('topic.reply_placeholder')) : t(sk('search.placeholder_target'), { target: shortId.value })),
  dock: () => ({ reply: Boolean(replyTarget()), target: shortId.value }),
  send: onSend,
  busy: () => sending.value,
})

watch([taskId, () => viewer.topics.length, phoneThread], async () => {
  const id = taskId.value
  if (!id || (stack.isMobile.value && phoneThread.value)) return
  await nextTick()
  const root = listBody.value
  if (!root) return
  const row = root.querySelector(`[data-key="${CSS.escape(id)}"]`)
  if (row) scrollRowToTop(root, row)
})

if (import.meta.client) {
  watch(taskId, async (id, prev) => {
    if (!id) return
    if (prev !== undefined) phoneThread.value = true
    await showTopic(id)
  }, { immediate: true })
}

let listStarted = false
watch(() => api.mock || String(session.state) === 'in', (ready) => {
  if (!ready || listStarted) return
  listStarted = true
  void viewer.loadTopics().then(() => {
    if (shouldOpenHubSocket(session.state, api.mock)) viewer.follow()
  })
}, { immediate: true })

onUnmounted(() => {
  viewer.unfollow()
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
