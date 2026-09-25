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
    <p v-if="clickable" id="feed-open-hint" class="sr-only">{{ t('feed.open_topic_hint') }}</p>
    <div class="new-pill-wrap">
      <button v-if="pill" class="btn new-pill" type="button" :aria-label="t('feed.new_pill_label')" data-testid="new-pill" @click="jump">
        ↑ {{ t('feed.new_pill', { n: pill }) }}
      </button>
    </div>
    <TransitionGroup name="prepend" tag="div" class="live-rows">
      <MessageCard
        v-for="(m, i) in rows"
        :key="m.msg_id"
        :msg="m"
        :posinset="i + 1"
        :setsize="hasOlder ? -1 : rows.length"
        :topic-link="openable(m)"
        :count="countFor ? countFor(String(m.task_id || '')) : 0"
        :always-topic="alwaysTopic"
        :clickable="clickable"
        :selected="isSelected(m)"
        :since-ms="sinceMs"
        :editable="canEdit(m)"
        :class="{ pending: m.pending }"
        :data-key="m.msg_id"
        :data-pending="m.pending ? 'true' : undefined"
        @open-topic="(row: SpoolMessage) => $emit('open-topic', row)"
        @edited="(row: SpoolMessage) => $emit('edited', row)"
        @deleted="(row: SpoolMessage) => $emit('deleted', row)"
      />
    </TransitionGroup>
    <p v-if="!loading && !rows.length" class="muted empty">{{ search ? t('feed.no_matches') : (emptyText || t('feed.empty')) }}</p>
    <div v-if="hasOlder" class="older-sentinel">
      <button
        class="btn ghost load-more"
        type="button"
        data-testid="load-more"
        :disabled="loadingOlder"
        :aria-busy="loadingOlder ? 'true' : 'false'"
        @click="$emit('older')"
      >
        {{ loadingOlder ? t('feed.loading_older') : t('feed.load_more') }}
      </button>
    </div>
    <p class="sr-only" aria-live="polite">{{ announce }}</p>
  </section>
</template>

<script setup lang="ts">
import type { SpoolMessage } from '~/types/spool'
import { useScrollAnchor } from '~/composables/useScrollAnchor'
import { useTopicStore } from '~/stores/topic'
import { isSelectedRow } from '~/utils/topic-open.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'

/* 013: newest first under the Omnibox; entering rows animate. The first page is 30 rows; a Load more
   button under the last row asks for the next 30 (held rows first, then the hub, before=<cursor>).
   US7: a reader scrolled down keeps their place when rows arrive on top, and gets a "new" pill. */
const props = defineProps<{
  rows: SpoolMessage[]
  hasOlder: boolean
  loading?: boolean
  /** the next older page is in flight — the button waits for it */
  loadingOlder?: boolean
  search?: string
  label: string
  lastLive?: SpoolMessage | null
  currentTaskId?: string | null
  /** /channel and /dm (X3): every card is a topic root with a reply count. */
  countFor?: (taskId: string) => number
  alwaysTopic?: boolean
  /** CLE-3427: a click (or Enter / Space) anywhere on a row opens its topic. */
  clickable?: boolean
  /** what "no rows" says here — in a topic pane that is "no replies yet". */
  emptyText?: string
  /** topic-pane clock (Date.now()); omitted on channel / lobby cards */
  sinceMs?: number
  /** A thread. A new row must not move this list, and nothing scrolls it back. */
  holdScroll?: boolean
}>()
defineEmits<{ older: [], 'clear-search': [], 'open-topic': [msg: SpoolMessage], edited: [msg: SpoolMessage], deleted: [msg: SpoolMessage] }>()

const { t } = useI18n({ useScope: 'global' })
const topic = useTopicStore()
const root = ref<HTMLElement | null>(null)
const { pill, jump } = useScrollAnchor(
  root,
  () => props.rows.map((m) => String(m.msg_id)),
  (id) => Boolean(props.rows.find((m) => m.msg_id === id)?.pending),
  () => props.holdScroll !== true,
)

const announce = computed(() => {
  const m = props.lastLive
  return m ? t('feed.announce_new', { who: `${m.from}${m.from_box ? '@' + m.from_box : ''}` }) : ''
})

/* CLE-3445: `e` is offered only on the viewer's OWN browser-authored rows —
   the hub refuses anything else, and a shortcut that opens an editor the
   server will 403 is a defect. The predicate lives in utils/msg-edit.mjs. */
const { canEdit } = useMessageEdit()

function openable(m: SpoolMessage) {
  return Boolean(m.task_id && props.currentTaskId && m.task_id !== props.currentTaskId)
}

/* The row the open topic is rooted at stays selected. The title in the
   right pane is selected as well, so selecting that pane does not clear this row. */
function isSelected(m: SpoolMessage) {
  return Boolean(props.clickable) && isSelectedRow(m, topic.target)
}
</script>
