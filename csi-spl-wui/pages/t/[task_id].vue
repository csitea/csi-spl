<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2><NuxtLink to="/">Threads</NuxtLink> / <code>{{ shortId }}</code></h2>
      <span class="muted">{{ store.messages.length }} · newest first · {{ live.state.value }}</span>
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
      <p v-if="store.error" class="muted">{{ store.error }}</p>
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
import { useLiveFeed } from '~/stores/live'
import { useLive } from '~/composables/useLive'

const route = useRoute()
const store = useLiveFeed('main')
const live = useLive()
const taskId = computed(() => String(route.params.task_id || ''))
const shortId = computed(() => taskId.value.slice(0, 8))
const replies = computed(() => store.thread.replies)

onMounted(() => {
  watch(taskId, (id) => { if (id) void store.open(id) }, { immediate: true })
})

async function onSend(text: string, _parent?: string, files?: File[]) {
  await store.send(text, files || [])
}
</script>
