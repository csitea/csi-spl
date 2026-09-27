<template>
  <aside
    v-if="pane.taskId"
    class="topic live-pane"
    :class="{ selected: topic.paneSelected }"
    data-pane="topic"
    data-test="topic-section"
    data-section="live"
    :data-selected="topic.paneSelected ? 'true' : undefined"
    :aria-label="heading"
    @click="onTopicPaneClick"
  >
    <!-- Owner 2026-09-26 (prd topic b8cbfbe1): one row - the X first, then the
         title on one line, cut with an ellipsis (full title on hover). SPL-945:
         the replies' height control at the right edge; lazy, so the shell's
         initial chunk does not grow. -->
    <header>
      <!-- SPL-989: on a phone the chevron is Back (level 3 -> 2); the X hides -->
      <MobileBack />
      <button
        class="icon-btn topic-close"
        type="button"
        data-test="live-topic-close"
        :aria-label="t('common.close')"
        :title="t('common.close')"
        @click="close()"
      >
        <UiIcon name="x" :size="18" />
      </button>
      <strong class="topic-heading__title" data-test="topic-heading" data-selected="true" aria-current="true" :title="heading">{{ heading }}</strong>
      <LazyCardClipControl pane="thread" />
    </header>
    <BornTopics />
    <div class="pinned-root feed-body" data-test="topic-root">
      <ViewTokenForm v-if="pane.door" :detail="pane.door.detail" @saved="pane.taskId && pane.open(pane.taskId)" />
      <ErrorNotice v-if="pane.error" :message="pane.error" source="live-pane" test-id="live-pane-error" />
      <LiveFeed
        clip
        clip-pane="thread"
        hold-scroll
        :label="t('topic.replies_label')"
        :rows="messages"
        :has-older="pane.hasOlder"
        :loading-older="pane.loadingOlder"
        @older="pane.loadOlder()"
        :loading="pane.loading"
        :search="pane.search"
        :last-live="pane.lastLive"
        :empty-text="t('topic.no_replies')"
        :since-ms="sinceMs"
        @clear-search="pane.setSearch('')"
        @edited="onEdited"
      />
    </div>
  </aside>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useLiveFeed } from '~/stores/live'
import { useTopicStore } from '~/stores/topic'
import { newestFirst } from '~/utils/feed.mjs'
import { topicTitleFromRows } from '~/utils/view-api.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import type { SpoolMessage } from '~/types/spool'

/* Messages prepend at the top. The newest row is first; an older one sits below it. */
const pane = useLiveFeed('pane')
const { t } = useI18n({ useScope: 'global' })
const sinceMs = useNowTick(() => Boolean(pane.taskId))
const topic = useTopicStore()
const { onTopicPaneClick } = useTopicPaneClick()

/*
 * CLE-3427 — two shapes of topic land in this pane.
 *
 * task-rooted (a /search hit, a topic row): the pane's own task holds the
 * root and its replies, as before — rootAndReplies over what it read.
 *
 * message-rooted (a #lobby row): the root is the clicked message, which is
 * NOT in the task this pane reads (that task holds only the replies to it,
 * and holds nothing at all until the first one is written). The feed hands
 * the row over as topic.rootMsg; a deep link that arrives without one looks
 * it up in the feed, and until the feed has it the pane shows the empty line
 * rather than promoting a reply to root.
 */
const target = computed(() => (topic.target && topic.target.taskId === pane.taskId ? topic.target : null))
const messageRooted = computed(() => target.value?.mode === 'message')
/* The clicked message is not in the task this pane reads. It joins the
   same newest-first list, so it sits where its time puts it. */
const messages = computed(() => {
  const rows = messageRooted.value
    ? [topic.rootMsg, ...pane.newestFirst].filter((m): m is SpoolMessage => Boolean(m))
    : pane.newestFirst
  return newestFirst(rows)
})
/* The open topic's own title, selected at the top of this pane. */
const heading = computed(() => {
  const text = topicTitleFromRows(pane.messages, messageRooted.value ? topic.rootMsg : null)
  return text ? t('topic.list_title', { text }) : t('topic.title')
})

/*
 * CLE-3445 — an edit landed. Which stores hold this row depends on the
 * topic's shape (a task-rooted pane reads its root from the feed store, a
 * MESSAGE-rooted one pins topic.rootMsg, which no feed owns) AND on the
 * route behind the panel, so the pane does not try to work it out: it tells
 * all of them. See applyEverywhere — the first version of this told two
 * stores and left the lobby feed behind the panel on the OLD body.
 */
const { applyEverywhere } = useMessageEdit()

function onEdited(row: SpoolMessage) {
  applyEverywhere(row)
}

function close() {
  pane.close()
  topic.close()
}
</script>
