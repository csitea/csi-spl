<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2>{{ tr('nav.topics') }}</h2>
      <span class="muted">{{ tr('pages.index.subtitle') }}</span>
    </header>
    <div ref="listTop" class="feed-body">
      <div class="new-pill-wrap">
        <button v-if="pill" class="btn new-pill" type="button" :aria-label="tr('feed.new_pill_label')" data-testid="new-pill" @click="jump">
          ↑ {{ tr('feed.new_pill', { n: pill }) }}
        </button>
      </div>
      <ErrorNotice v-if="viewer.error" :message="viewer.error" source="viewer" test-id="viewer-error" />
      <ViewTokenForm v-if="viewer.needsToken" :detail="viewer.doorDetail" @saved="viewer.loadTopics()" />
      <p v-else-if="!viewer.loading && !viewer.error && viewer.topics.length === 0" class="muted">
        {{ tr('pages.index.empty') }}
      </p>
      <a
        v-for="t in viewer.topics"
        :key="t.task_id"
        class="topic-row"
        :data-key="t.task_id"
        :data-ts="t.last_ts || undefined"
        :href="localePath('/t/' + t.task_id)"
        @click.exact.prevent="pane.open(t.task_id)"
      >
        <div class="msg-meta">
          <span class="msg-author">{{ t.participants.join(', ') || t.task_id }}</span>
          <KindBadge v-for="k in Object.keys(t.kinds)" :key="k" :kind="k" />
          <span class="msg-time">{{ formatTs(t.last_ts, locale) }}</span>
        </div>
        <div class="topic-subject">{{ t.subject }}</div>
        <small class="muted">{{ tr('pages.index.messages', { n: t.count }, t.count) }}</small>
      </a>
      <button v-if="viewer.next" class="btn ghost" type="button" @click="viewer.loadMore()">{{ tr('pages.index.older') }}</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useTopicStore } from '~/stores/topic'
import { useViewerStore } from '~/stores/viewer'
import type { SpoolMessage } from '~/types/spool'
import { useLiveFeed } from '~/stores/live'
import { formatTs } from '~/utils/channel-feed.mjs'
import { bumpTopic } from '~/utils/topic-list.mjs'
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useSettledQuery } from '~/composables/useSettledQuery'
import { useScrollAnchor } from '~/composables/useScrollAnchor'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { shouldOpenHubSocket } from '~/utils/shell-bootstrap.mjs'
import { useSidePane } from '~/composables/useSidePane'
import { omniboxReplyTaskId } from '~/utils/omnibox-topic.mjs'

const viewer = useViewerStore()
const channel = useChannelStore()
const topicStore = useTopicStore()
const session = useSessionStore()
const api = useSpoolApi()
/* `tr`, not `t`: the topic rows below are iterated as `t` */
const { t: tr, locale } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
/* 013 US3: a click opens the topic in the right pane; the link still works for new tabs */
const pane = useLiveFeed('pane')
const sidePane = useSidePane()
/* deep link: /?topic=<task_id> opens the right pane. `/` is prerendered, so
   the query only exists once hydration settles (useSettledQuery). */
const topic = useSettledQuery('topic')
onMounted(() => {
  watch(topic.value, (id) => {
    if (/^[0-9a-f-]{36}$/i.test(id)) void pane.open(id)
  }, { immediate: true })
})
/* 013 US7: newest activity on top, live over the socket; a reader scrolled down keeps their place */
const listTop = ref<HTMLElement | null>(null)
const { pill, jump } = useScrollAnchor(listTop, () => viewer.topics.map((r) => r.task_id))
/* W5 (GRK-3377): `/` opened the hub socket while signed out - viewer.follow()
   calls live.ensure(), which constructs and connects a client, and the hub
   answers the upgrade 401, so a signed-out visitor got 4 attempts plus backoff
   (measured on both apexes, tree e52e250). The read and the follow now wait for
   a member session, on the same predicate as the rest of the shell; a sign-in
   flips the same store, so a human who signs in gets both with no reload. */
/* Topics tab with a selected row: the omnibox replies in that topic.
   `in: <title>` still names the topic. Anything else, or Topics with
   nothing selected, starts a new message. */
async function onSend(text: string, files?: File[], topicId?: string, channelId?: string) {
  const target = omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: pane.taskId || '',
    namedTopicId: topicId || '',
  })
  if (target && pane.taskId && target === pane.taskId) {
    const before = pane.messages.length
    await pane.send(text, files || [])
    const last = pane.messages[pane.messages.length - 1]
    if (last && pane.messages.length > before) {
      viewer.topics = bumpTopic(viewer.topics, last as unknown as Record<string, unknown>) as typeof viewer.topics
    }
    return
  }
  const sent = await channel.send(text, target || undefined, files, channelId)
  /* A send with no topic is a new topic of this one message, so the row
     has to appear here itself. The socket echo does not count a second time. */
  if (sent) viewer.topics = bumpTopic(viewer.topics, sent as unknown as Record<string, unknown>) as typeof viewer.topics
  topicStore.noteBorn(topicStore.open || Boolean(pane.taskId), target, sent as SpoolMessage)
}
useOmniboxTarget({
  placeholder: () => (omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: pane.taskId || '',
    namedTopicId: '',
  }) ? tr('topic.reply_placeholder') : tr('search.placeholder_target', { target: tr('nav.topics') })),
  send: onSend,
})

let listStarted = false
watch(() => api.mock || String(session.state) === 'in', (ready) => {
  if (!ready || listStarted) return
  listStarted = true
  /* the mock tenant has no door and no socket: it reads at once and follows
     nothing (viewer.follow() returns early there) */
  void viewer.loadTopics().then(() => {
    if (shouldOpenHubSocket(session.state, api.mock)) viewer.follow()
  })
}, { immediate: true })
onUnmounted(() => viewer.unfollow())
</script>
