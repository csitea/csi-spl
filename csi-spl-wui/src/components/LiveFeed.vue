<template>
  <section
    class="live-feed"
    role="feed"
    :aria-busy="loading ? 'true' : 'false'"
    :aria-label="label"
  >
    <p v-if="search" class="search-chip">
      Filter: <strong>{{ search }}</strong> · {{ rows.length }}{{ hasOlder ? '+' : '' }} match(es)
      <button class="btn ghost" type="button" @click="$emit('clear-search')">Clear</button>
    </p>
    <TransitionGroup name="prepend" tag="div" class="live-rows">
      <MessageCard
        v-for="(m, i) in rows"
        :key="m.msg_id"
        :msg="m"
        :posinset="i + 1"
        :setsize="hasOlder ? -1 : rows.length"
        :thread-link="openable(m)"
        @open-thread="(id: string) => $emit('open-thread', id)"
      />
    </TransitionGroup>
    <p v-if="!loading && !rows.length" class="muted empty">{{ search ? 'No messages match.' : 'No messages yet.' }}</p>
    <div ref="sentinel" class="older-sentinel" aria-hidden="true">
      <span v-if="hasOlder" class="muted">Loading older…</span>
    </div>
    <p class="sr-only" aria-live="polite">{{ announce }}</p>
  </section>
</template>

<script setup lang="ts">
import type { SpoolMessage } from '~/types/spool'

/* 013: newest first under the Omnibox; entering rows animate; the bottom sentinel loads older windows. */
const props = defineProps<{
  rows: SpoolMessage[]
  hasOlder: boolean
  loading?: boolean
  search?: string
  label: string
  lastLive?: SpoolMessage | null
  currentTaskId?: string | null
}>()
const emit = defineEmits<{ older: [], 'clear-search': [], 'open-thread': [id: string] }>()

const sentinel = ref<HTMLElement | null>(null)
let io: IntersectionObserver | null = null
onMounted(() => {
  if (typeof IntersectionObserver === 'undefined' || !sentinel.value) return
  io = new IntersectionObserver((entries) => {
    if (entries.some((e) => e.isIntersecting) && props.hasOlder) emit('older')
  }, { rootMargin: '200px' })
  io.observe(sentinel.value)
})
onUnmounted(() => io?.disconnect())

const announce = computed(() => {
  const m = props.lastLive
  return m ? `New message from ${m.from}${m.from_box ? '@' + m.from_box : ''}` : ''
})

function openable(m: SpoolMessage) {
  return Boolean(m.task_id && props.currentTaskId && m.task_id !== props.currentTaskId)
}
</script>
