<template>
  <aside v-if="pane.taskId" class="thread live-pane" data-test="thread-section" data-section="live" :aria-label="t('thread.title')">
    <header>
      <strong>{{ t('thread.title') }} <code>{{ pane.taskId.slice(0, 8) }}</code></strong>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;min-width:0">
        <VerbositySelector />
        <NuxtLink
          v-if="!messageRooted"
          class="icon-btn icon-btn--accent"
          data-test="live-thread-open"
          :to="localePath('/t/' + pane.taskId)"
          :aria-label="t('thread.open')"
          :title="t('thread.open')"
        >
          <UiIcon name="open" :size="18" />
        </NuxtLink>
        <button
          class="icon-btn"
          type="button"
          data-test="live-thread-close"
          :aria-label="t('common.close')"
          :title="t('common.close')"
          @click="close()"
        >
          <UiIcon name="x" :size="18" />
        </button>
      </div>
    </header>
    <div class="pinned-root" data-test="thread-root">
      <MessageCard v-if="root" :msg="root" />
      <p v-else-if="!pane.loading" class="muted">{{ t('thread.empty') }}</p>
    </div>
    <MessageComposer
      omnibox
      :placeholder="t('thread.reply_placeholder')"
      :busy="pane.sending"
      @send="onSend"
      @search="pane.setSearch"
    />
    <div class="feed-body">
      <ViewTokenForm v-if="pane.door" :detail="pane.door.detail" @saved="pane.taskId && pane.open(pane.taskId)" />
      <ErrorNotice v-if="pane.error" :message="pane.error" source="live-pane" test-id="live-pane-error" />
      <LiveFeed
        :label="t('thread.replies_label')"
        :rows="replies"
        :has-older="false"
        :loading="pane.loading"
        :search="pane.search"
        :last-live="pane.lastLive"
        :empty-text="t('thread.no_replies')"
        @clear-search="pane.setSearch('')"
      />
    </div>
  </aside>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useLiveFeed } from '~/stores/live'
import { useThreadStore } from '~/stores/thread'
import { applyVerbosity } from '~/utils/verbosity.mjs'
import type { SpoolMessage } from '~/types/spool'

/* 013 US3: pinned root (oldest of the task_id), reply Omnibox, newest-first replies, live. */
const pane = useLiveFeed('pane')
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const thread = useThreadStore()

/*
 * CLE-3427 — two shapes of thread land in this pane.
 *
 * task-rooted (a /search hit, a thread row): the pane's own task holds the
 * root and its replies, as before — rootAndReplies over what it read.
 *
 * message-rooted (a #lobby row): the root is the clicked message, which is
 * NOT in the task this pane reads (that task holds only the replies to it,
 * and holds nothing at all until the first one is written). The feed hands
 * the row over as thread.rootMsg; a deep link that arrives without one looks
 * it up in the feed, and until the feed has it the pane shows the empty line
 * rather than promoting a reply to root.
 */
const target = computed(() => (thread.target && thread.target.taskId === pane.taskId ? thread.target : null))
const messageRooted = computed(() => target.value?.mode === 'message')
const root = computed<SpoolMessage | null>(() => (messageRooted.value ? thread.rootMsg : pane.thread.root))
const replies = computed(() => applyVerbosity(messageRooted.value ? pane.newestFirst : pane.thread.replies, thread.verbosity))

function close() {
  pane.close()
  thread.close()
}

async function onSend(text: string, _parent?: string, files?: File[]) {
  /* a reply in a message-rooted thread says which task it hangs off and which
     channel it belongs to, so the thread is reachable from that channel */
  const t = target.value
  await pane.send(text, files || [], t && t.mode === 'message'
    ? { parentTaskId: t.parentTaskId, channel: root.value?.channel || undefined }
    : {})
}
</script>
