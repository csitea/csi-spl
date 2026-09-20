<template>
  <aside v-if="pane.taskId" class="thread live-pane" :aria-label="t('thread.title')">
    <header>
      <strong>{{ t('thread.title') }} <code>{{ pane.taskId.slice(0, 8) }}</code></strong>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;min-width:0">
        <VerbositySelector />
        <NuxtLink
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
          @click="pane.close()"
        >
          <UiIcon name="x" :size="18" />
        </button>
      </div>
    </header>
    <div class="pinned-root">
      <MessageCard v-if="pane.thread.root" :msg="pane.thread.root" />
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

/* 013 US3: pinned root (oldest of the task_id), reply Omnibox, newest-first replies, live. */
const pane = useLiveFeed('pane')
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const thread = useThreadStore()
const replies = computed(() => applyVerbosity(pane.thread.replies, thread.verbosity))

async function onSend(text: string, _parent?: string, files?: File[]) {
  await pane.send(text, files || [])
}
</script>
