<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2>Threads</h2>
      <span class="muted">read-only · tenant-scoped</span>
    </header>
    <div class="feed-body">
      <p v-if="viewer.error" class="muted">{{ viewer.error }}</p>
      <ViewTokenForm v-if="viewer.needsToken" @saved="viewer.loadThreads()" />
      <p v-else-if="!viewer.loading && !viewer.error && viewer.threads.length === 0" class="muted">
        No threads yet.
      </p>
      <NuxtLink
        v-for="t in viewer.threads"
        :key="t.task_id"
        class="thread-row"
        :to="'/t/' + t.task_id"
      >
        <div class="msg-meta">
          <span class="msg-author">{{ t.participants.join(', ') || t.task_id }}</span>
          <KindBadge v-for="k in Object.keys(t.kinds)" :key="k" :kind="k" />
          <span class="msg-time">{{ formatTs(t.last_ts) }}</span>
        </div>
        <div class="thread-subject">{{ t.subject }}</div>
        <small class="muted">{{ t.count }} {{ t.count === 1 ? 'message' : 'messages' }}</small>
      </NuxtLink>
      <button v-if="viewer.next" class="btn ghost" type="button" @click="viewer.loadMore()">Older</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useViewerStore } from '~/stores/viewer'
import { formatTs } from '~/utils/channel-feed.mjs'

const viewer = useViewerStore()
onMounted(() => viewer.loadThreads())
</script>
