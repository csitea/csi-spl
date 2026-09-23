<template>
  <aside v-if="pane.taskId" class="topic live-pane" data-test="topic-section" data-section="live" :aria-label="t('topic.title')">
    <header>
      <strong>{{ t('topic.title') }} <code>{{ pane.taskId.slice(0, 8) }}</code></strong>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;min-width:0">
        <VerbositySelector />
        <NuxtLink
          v-if="!messageRooted"
          class="icon-btn icon-btn--accent"
          data-test="live-topic-open"
          :to="localePath('/t/' + pane.taskId)"
          :aria-label="t('topic.open')"
          :title="t('topic.open')"
        >
          <UiIcon name="open" :size="18" />
        </NuxtLink>
        <button
          class="icon-btn"
          type="button"
          data-test="live-topic-close"
          :aria-label="t('common.close')"
          :title="t('common.close')"
          @click="close()"
        >
          <UiIcon name="x" :size="18" />
        </button>
      </div>
    </header>
    <BornTopics />
    <div class="pinned-root" data-test="topic-root">
      <MessageCard v-if="root" :key="String(root.msg_id || '')" :msg="root" :since-ms="sinceMs" :editable="canEdit(root)" @edited="onEdited" />
      <p v-else-if="!pane.loading" class="muted">{{ t('topic.empty') }}</p>
    </div>
    <div class="feed-body">
      <ViewTokenForm v-if="pane.door" :detail="pane.door.detail" @saved="pane.taskId && pane.open(pane.taskId)" />
      <ErrorNotice v-if="pane.error" :message="pane.error" source="live-pane" test-id="live-pane-error" />
      <LiveFeed
        :label="t('topic.replies_label')"
        :rows="replies"
        :has-older="false"
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
import { applyVerbosity } from '~/utils/verbosity.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import type { SpoolMessage } from '~/types/spool'

/* 013 US3: pinned root (oldest of the task_id), reply Omnibox, newest-first replies, live. */
const pane = useLiveFeed('pane')
const { t } = useI18n({ useScope: 'global' })
const sinceMs = useNowTick(() => Boolean(pane.taskId))
const localePath = useLocalePath()
const topic = useTopicStore()

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
const root = computed<SpoolMessage | null>(() => (messageRooted.value ? topic.rootMsg : pane.topic.root))
const replies = computed(() => applyVerbosity(messageRooted.value ? pane.newestFirst : pane.topic.replies, topic.verbosity))

/*
 * CLE-3445 — an edit landed. Which stores hold this row depends on the
 * topic's shape (a task-rooted pane reads its root from the feed store, a
 * MESSAGE-rooted one pins topic.rootMsg, which no feed owns) AND on the
 * route behind the panel, so the pane does not try to work it out: it tells
 * all of them. See applyEverywhere — the first version of this told two
 * stores and left the lobby feed behind the panel on the OLD body.
 */
const { canEdit, applyEverywhere } = useMessageEdit()

function onEdited(row: SpoolMessage) {
  applyEverywhere(row)
}

function close() {
  pane.close()
  topic.close()
}
</script>
