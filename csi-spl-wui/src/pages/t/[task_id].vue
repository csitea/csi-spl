<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2><NuxtLink :to="localePath('/')">{{ t('nav.topics') }}</NuxtLink> / <code>{{ shortId }}</code></h2>
      <span class="muted">{{ t('pages.task.status', { n: store.messages.length, state: stateLabel(live.state.value) }) }}</span>
      <!-- SPL-963: the thread's control, as in the right pane -->
      <LazyCardClipControl pane="thread" />
    </header>
    <div class="pinned-root feed-body" data-test="topic-root">
      <ViewTokenForm v-if="store.door" :detail="store.door.detail" @saved="reopen" />
      <ErrorNotice v-if="store.error" :message="store.error" source="topic" test-id="topic-error" />
      <LiveFeed
        clip
        clip-pane="thread"
        hold-scroll
        :label="t('topic.replies_label')"
        :rows="messages"
        :has-older="store.hasOlder"
        :loading-older="store.loadingOlder"
        @older="store.loadOlder()"
        :loading="store.loading"
        :search="store.search"
        :last-live="store.lastLive"
        :since-ms="sinceMs"
        @clear-search="store.setSearch('')"
        @edited="onEdited"
      />
    </div>
  </div>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useLive } from '~/composables/useLive'
import { useTopicStore } from '~/stores/topic'
import { newestFirst } from '~/utils/feed.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import type { SpoolMessage } from '~/types/spool'
import { useSidePane } from '~/composables/useSidePane'
import { isParentFlag, omniboxReplyTaskId } from '~/utils/omnibox-topic.mjs'

const route = useRoute()
const store = useLiveFeed('main')
const side = useLiveFeed('pane')
const channel = useChannelStore()
const live = useLive()
const { t, te } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
/** Socket state token (open, reconnecting, …) in words; an unknown token (a config error) shows as is. */
const stateLabel = (s: string) => (te('feed.live_state.' + s) ? t('feed.live_state.' + s) : s)
const taskId = computed(() => String(route.params.task_id || ''))
const shortId = computed(() => taskId.value.slice(0, 8))
const topic = useTopicStore()
const sidePane = useSidePane()
const sinceMs = useNowTick(() => Boolean(taskId.value))
const messages = computed(() => newestFirst(store.newestFirst))

function reopen() {
  if (taskId.value) void store.open(taskId.value, { all: true })
}

onMounted(() => {
  watch(taskId, reopen, { immediate: true })
})

/* CLE-3445: an edit landed on this page's own feed store (the live store
   already applies a `message_edited` frame from another session itself). */
const { applyEverywhere } = useMessageEdit()

function onEdited(row: SpoolMessage) {
  applyEverywhere(row)
}

/* Topics tab with this task selected: the omnibox replies here. `in:`
   naming another topic still goes there. A different left tab starts a new message. */
async function onSend(text: string, files?: File[], topicId?: string, channelId?: string) {
  const target = omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: taskId.value,
    namedTopicId: topicId || '',
    paneVisible: true,
  })
  if (target && target === taskId.value && store.taskId) {
    await store.send(text, files || [], { isParent: isParentFlag({ paneVisible: true }) })
    return
  }
  const sent = await channel.send(text, target || undefined, files, channelId, isParentFlag({ paneVisible: Boolean(target) }))
  topic.noteBorn(topic.open || Boolean(side.taskId), target, sent as SpoolMessage)
}
useOmniboxTarget({
  placeholder: () => (omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: taskId.value,
    namedTopicId: '',
    paneVisible: true,
  }) ? t('topic.reply_placeholder') : t('search.placeholder_target', { target: shortId.value })),
  send: onSend,
  busy: () => store.sending,
})
</script>
