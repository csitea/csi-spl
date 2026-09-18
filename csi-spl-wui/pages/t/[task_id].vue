<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2><NuxtLink to="/">Threads</NuxtLink> / <code>{{ shortId }}</code></h2>
      <span class="muted">{{ viewer.messages.length }} · oldest first</span>
    </header>
    <div class="feed-body">
      <p v-if="viewer.error" class="muted">{{ viewer.error }}</p>
      <ViewTokenForm v-if="viewer.needsToken" @saved="viewer.refreshThread()" />
      <MessageCard v-for="m in viewer.messages" :key="m.msg_id" :msg="m" />
    </div>
  </div>
</template>

<script setup lang="ts">
import { useViewerStore } from '~/stores/viewer'

const route = useRoute()
const config = useRuntimeConfig()
const viewer = useViewerStore()
const taskId = computed(() => String(route.params.task_id || ''))
const shortId = computed(() => taskId.value.slice(0, 8))

/** US4: poll while visible; view-v1 §4.4 asks for no more than one poll per 2 s. */
const pollMs = Math.max(2000, Number(config.public.pollMs) || 4000)
let timer: ReturnType<typeof setInterval> | null = null

function stop() {
  if (timer) clearInterval(timer)
  timer = null
}

watch(taskId, (id) => {
  if (id) void viewer.openThread(id)
}, { immediate: true })

onMounted(() => {
  timer = setInterval(() => {
    if (document.visibilityState === 'visible' && !viewer.needsToken) void viewer.refreshThread()
  }, pollMs)
})
onUnmounted(stop)
</script>
