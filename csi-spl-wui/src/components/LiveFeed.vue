<template>
  <section
    ref="root"
    class="live-feed"
    role="feed"
    :aria-busy="loading ? 'true' : 'false'"
    :aria-label="label"
  >
    <p v-if="search" class="search-chip">
      {{ t('feed.filter_label') }} <strong>{{ search }}</strong> · {{ t('feed.matches', { count: rows.length + (hasOlder ? '+' : '') }) }}
      <button class="btn ghost" type="button" @click="$emit('clear-search')">{{ t('feed.clear') }}</button>
    </p>
    <button v-if="pill" class="btn new-pill" type="button" :aria-label="t('feed.new_pill_label')" data-testid="new-pill" @click="jump">
      ↑ {{ t('feed.new_pill', { n: pill }) }}
    </button>
    <TransitionGroup name="prepend" tag="div" class="live-rows">
      <MessageCard
        v-for="(m, i) in rows"
        :key="m.msg_id"
        :msg="m"
        :posinset="i + 1"
        :setsize="hasOlder ? -1 : rows.length"
        :thread-link="openable(m)"
        :count="countFor ? countFor(String(m.task_id || '')) : 0"
        :always-thread="alwaysThread"
        :class="{ pending: m.pending }"
        :data-pending="m.pending ? 'true' : undefined"
        @open-thread="(id: string) => $emit('open-thread', id)"
      />
    </TransitionGroup>
    <p v-if="!loading && !rows.length" class="muted empty">{{ search ? t('feed.no_matches') : t('feed.empty') }}</p>
    <div ref="sentinel" class="older-sentinel" aria-hidden="true">
      <span v-if="hasOlder" class="muted">{{ t('feed.loading_older') }}</span>
    </div>
    <p class="sr-only" aria-live="polite">{{ announce }}</p>
  </section>
</template>

<script setup lang="ts">
import type { SpoolMessage } from '~/types/spool'
import { useScrollAnchor } from '~/composables/useScrollAnchor'

/* 013: newest first under the Omnibox; entering rows animate; the bottom sentinel loads older windows.
   US7: a reader scrolled down keeps their place when rows arrive on top, and gets a "new" pill. */
const props = defineProps<{
  rows: SpoolMessage[]
  hasOlder: boolean
  loading?: boolean
  search?: string
  label: string
  lastLive?: SpoolMessage | null
  currentTaskId?: string | null
  /** /channel and /dm (X3): every card is a thread root with a reply count. */
  countFor?: (taskId: string) => number
  alwaysThread?: boolean
}>()
const emit = defineEmits<{ older: [], 'clear-search': [], 'open-thread': [id: string] }>()

const { t } = useI18n({ useScope: 'global' })
const sentinel = ref<HTMLElement | null>(null)
const root = ref<HTMLElement | null>(null)
const { pill, jump } = useScrollAnchor(
  root,
  () => props.rows.map((m) => String(m.msg_id)),
  (id) => Boolean(props.rows.find((m) => m.msg_id === id)?.pending),
)
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
  return m ? t('feed.announce_new', { who: `${m.from}${m.from_box ? '@' + m.from_box : ''}` }) : ''
})

function openable(m: SpoolMessage) {
  return Boolean(m.task_id && props.currentTaskId && m.task_id !== props.currentTaskId)
}
</script>
