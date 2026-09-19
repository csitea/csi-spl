<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2><NuxtLink to="/">Threads</NuxtLink> / <code>{{ shortId }}</code></h2>
      <span class="muted">{{ store.messages.length }} · newest first · {{ live.state.value }}</span>
      <VerbositySelector />
    </header>
    <div class="pinned-root">
      <MessageCard v-if="store.thread.root" :msg="store.thread.root" />
    </div>
    <MessageComposer
      omnibox
      placeholder="Reply — Enter to send · /search to filter"
      :busy="store.sending"
      @send="onSend"
      @search="store.setSearch"
    />
    <div class="feed-body">
      <ViewTokenForm v-if="store.door" :detail="store.door.detail" @saved="reopen" />
      <ErrorNotice v-if="store.error" :message="store.error" source="thread" test-id="thread-error" />
      <LiveFeed
        label="Replies, newest first"
        :rows="replies"
        :has-older="false"
        :loading="store.loading"
        :search="store.search"
        :last-live="store.lastLive"
        @clear-search="store.setSearch('')"
      />
    </div>
  </div>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useLiveFeed } from '~/stores/live'
import { useLive } from '~/composables/useLive'
import { useThreadStore } from '~/stores/thread'
import { applyVerbosity } from '~/utils/verbosity.mjs'

const route = useRoute()
const store = useLiveFeed('main')
const live = useLive()
const taskId = computed(() => String(route.params.task_id || ''))
const shortId = computed(() => taskId.value.slice(0, 8))
const thread = useThreadStore()
/* 005 FR-013: the same verbosity filter as the thread pane */
const replies = computed(() => applyVerbosity(store.thread.replies, thread.verbosity))

function reopen() {
  if (taskId.value) void store.open(taskId.value, { all: true })
}

onMounted(() => {
  watch(taskId, reopen, { immediate: true })
})

async function onSend(text: string, _parent?: string, files?: File[]) {
  await store.send(text, files || [])
}
</script>
