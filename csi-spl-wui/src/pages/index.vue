<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2>Threads</h2>
      <span class="muted">read-only · tenant-scoped</span>
    </header>
    <div class="feed-body">
      <ErrorNotice v-if="viewer.error" :message="viewer.error" source="viewer" test-id="viewer-error" />
      <ViewTokenForm v-if="viewer.needsToken" @saved="viewer.loadThreads()" />
      <p v-else-if="!viewer.loading && !viewer.error && viewer.threads.length === 0" class="muted">
        No threads yet.
      </p>
      <a
        v-for="t in viewer.threads"
        :key="t.task_id"
        class="thread-row"
        :href="'/t/' + t.task_id"
        @click.exact.prevent="pane.open(t.task_id)"
      >
        <div class="msg-meta">
          <span class="msg-author">{{ t.participants.join(', ') || t.task_id }}</span>
          <KindBadge v-for="k in Object.keys(t.kinds)" :key="k" :kind="k" />
          <span class="msg-time">{{ formatTs(t.last_ts) }}</span>
        </div>
        <div class="thread-subject">{{ t.subject }}</div>
        <small class="muted">{{ t.count }} {{ t.count === 1 ? 'message' : 'messages' }}</small>
      </a>
      <button v-if="viewer.next" class="btn ghost" type="button" @click="viewer.loadMore()">Older</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useViewerStore } from '~/stores/viewer'
import { useLiveFeed } from '~/stores/live'
import { formatTs } from '~/utils/channel-feed.mjs'
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useSettledQuery } from '~/composables/useSettledQuery'

const viewer = useViewerStore()
/* 013 US3: a click opens the thread in the right pane; the link still works for new tabs */
const pane = useLiveFeed('pane')
/* deep link: /?thread=<task_id> opens the right pane. `/` is prerendered, so
   the query only exists once hydration settles (useSettledQuery). */
const thread = useSettledQuery('thread')
onMounted(() => {
  watch(thread.value, (id) => {
    if (/^[0-9a-f-]{36}$/i.test(id)) void pane.open(id)
  }, { immediate: true })
})
onMounted(() => viewer.loadThreads())
</script>
