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
    <div v-if="!newestLast" class="new-pill-wrap">
      <button v-if="pill" class="btn new-pill" type="button" :aria-label="t('feed.new_pill_label')" data-testid="new-pill" @click="jump">
        ↑ {{ t('feed.new_pill', { n: pill }) }}
      </button>
    </div>
    <!-- Newest last (topic c6994436): Load more for older rows sits ABOVE the
         first row, where the older rows go. -->
    <div v-if="newestLast && hasOlder" class="older-sentinel older-sentinel--top">
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
    <!-- 8f588edd: the topics-list background is a drop zone - a reply dragged
         here (not onto a card) is PROMOTED into a new topic of its own. Only
         the middle pane (openButton) offers it; a reply dropped on a card
         still MOVES there (the card's own data-move-drop wins under the
         pointer). -->
    <TransitionGroup
      :name="newestLast ? 'append' : 'prepend'"
      tag="div"
      class="live-rows"
      :data-order="newestLast ? 'newest-last' : undefined"
      :data-move-drop="openButton ? 'topics' : undefined"
      :data-move-id="openButton && promoteDrag ? 'promote' : undefined"
      :data-move-ok="openButton && promoteDrag ? 'true' : undefined"
    >
      <MessageCard
        v-for="(m, i) in shown"
        :key="m.msg_id"
        :msg="m"
        :posinset="i + 1"
        :setsize="hasOlder ? -1 : shown.length"
        :topic-link="openable(m)"
        :count="countFor ? countFor(String(m.task_id || '')) : 0"
        :always-topic="alwaysTopic"
        :clickable="clickable"
        :selected="isSelected(m)"
        :since-ms="sinceMs"
        :editable="canEdit(m)"
        :merge-prev="mergeTarget(m, 'previous')"
        :merge-next="mergeTarget(m, 'next')"
        :current-task-id="currentTaskId"
        :clip-mode="clipModeFor()"
        :topic-menu="openButton"
        :move-ctx="moveCtx"
        :class="{ pending: m.pending }"
        :data-key="m.msg_id"
        :data-pending="m.pending ? 'true' : undefined"
        @open-topic="(row: SpoolMessage) => $emit('open-topic', row)"
        @edited="(row: SpoolMessage) => $emit('edited', row)"
        @deleted="(row: SpoolMessage) => $emit('deleted', row)"
        @reacted="(update: ReactionUpdate) => $emit('reacted', update)"
      />
    </TransitionGroup>
    <p v-if="!loading && !rows.length" class="muted empty">{{ search ? t('feed.no_matches') : (emptyText || t('feed.empty')) }}</p>
    <div v-if="newestLast" class="new-pill-wrap new-pill-wrap--bottom">
      <button v-if="pill" class="btn new-pill" type="button" :aria-label="t('feed.new_pill_label')" data-testid="new-pill" @click="jump">
        ↓ {{ t('feed.new_pill', { n: pill }) }}
      </button>
    </div>
    <div v-if="hasOlder && !newestLast" class="older-sentinel">
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
import type { ReactionUpdate, SpoolMessage } from '~/types/spool'
import { useScrollAnchor } from '~/composables/useScrollAnchor'
import { useTopicStore } from '~/stores/topic'
import { isSelectedRow } from '~/utils/topic-open.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { mergeableSourceIn, neighborIn, threadNeighbors } from '~/utils/msg-menu.mjs'
import { useLive } from '~/composables/useLive'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { useCardClip, type CardClipPane } from '~/composables/useCardClip'
import { useViewPrefs } from '~/composables/useViewPrefs'
import { displayOrder } from '~/utils/view-prefs.mjs'
import { useMove } from '~/composables/useMove'

/* 013: newest first under the Omnibox; entering rows animate. The first page is 30 rows; a Load more
   button under the last row asks for the next 30 (held rows first, then the hub, before=<cursor>).
   US7: a reader scrolled down keeps their place when rows arrive on top, and gets a "new" pill.
   Topic c6994436: `rows` always come newest first (so every window holds the
   newest N); a person who picked "newest last" sees them reversed, Load more
   above the first row, and the pill (↓) at the bottom. */
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
  /** a click (or Enter / Space) anywhere on a row opens its topic. */
  clickable?: boolean
  /** what "no rows" says here — in a topic pane that is "no replies yet". */
  emptyText?: string
  /** topic-pane clock (Date.now()); omitted on channel / lobby cards */
  sinceMs?: number
  /** A thread. A new row must not move this list, and nothing scrolls it back. */
  holdScroll?: boolean
  /** The middle pane: every card carries the Open button, which opens its
      topic in the right (threads) pane. Owner, 2026-09-25: "the button should
      be displayed only on the middle pane and it should work so that it will
      open the topic". A thread pane never passes it. */
  openButton?: boolean
  /** a middle-pane feed of level-1 cards takes the pane's height
      mode (titles / 5 rows / full). SPL-945: a thread (the right pane, the
      /t page) passes it too, with clipPane="thread" - its own mode. SPL-963:
      the thread's root card takes that mode as well, so the buttons change
      a thread that has no replies yet. */
  clip?: boolean
  clipPane?: CardClipPane
  /** SPL-1024: a thread whose rows may be moved to another topic (the right pane). */
  moveCtx?: { channel?: string | null, opener?: string, topic?: string } | null
}>()
defineEmits<{ older: [], 'clear-search': [], 'open-topic': [msg: SpoolMessage], edited: [msg: SpoolMessage], deleted: [msg: SpoolMessage], reacted: [update: ReactionUpdate] }>()

const { t } = useI18n({ useScope: 'global' })
/* 8f588edd: the topics-list background lights up while a reply is being dragged. */
const move = useMove()
const promoteDrag = computed(() => Boolean(move.drag.value && move.drag.value.kind === 'message'))
const topic = useTopicStore()
const people = useHumanNames()
const { mode: clipMode } = useCardClip(props.clipPane)
function clipModeFor() {
  return props.clip ? clipMode.value : undefined
}
const root = ref<HTMLElement | null>(null)
const { newestLast } = useViewPrefs()
/* the rows in DOM (= reading) order */
const shown = computed(() => displayOrder(props.rows, newestLast.value ? 'newest-last' : 'newest-first') as SpoolMessage[])
/* Newest last: a thread follows new replies too while its reader sits at the
   bottom (A6); a reader scrolled up in it is never moved. */
const { pill, jump, hold } = useScrollAnchor(
  root,
  () => shown.value.map((m) => String(m.msg_id)),
  (id) => Boolean(props.rows.find((m) => m.msg_id === id)?.pending),
  () => props.holdScroll !== true || newestLast.value,
  () => newestLast.value,
)

const announce = computed(() => {
  const m = props.lastLive
  /* SPL-6: a named human is announced by the display name; anyone else as id@box */
  return m ? t('feed.announce_new', { who: people.label(String(m.from || ''), m.from_box) }) : ''
})

/* `e` is offered only on the viewer's OWN browser-authored rows —
   the hub refuses anything else, and a shortcut that opens an editor the
   server will 403 is a defect. The predicate lives in utils/msg-edit.mjs. */
const { canEdit } = useMessageEdit()

const liveConn = useLive()

/** The neighbor in this thread the viewer can both edit and, by deleting this row, fold into. */
/* one sort per thread per `rows`, read twice per card (CLE-35075) */
const neighbors = computed(() => threadNeighbors(props.rows))
function mergeTarget(m: SpoolMessage, which: 'previous' | 'next') {
  if (!canEdit(m)) return null
  const other = neighborIn(neighbors.value, m, which) as SpoolMessage | null
  if (!other || !canEdit(other)) return null
  /* a topic's card is never merged away (hub 409 is_card) */
  if (!mergeableSourceIn(neighbors.value, m, liveConn.lobbyTaskId.value)) return null
  return other
}

/* A pasted link to a thread line (#<msg_id>) moves that line to the top of
   its list once it has loaded, and selects it. Only a thread feed does this,
   and only once per hash, so later rows do not pull the reader back. The
   document itself does not scroll. */
const route = useRoute()
let hashDone = ''
watch(() => [route.hash, props.rows.length] as const, async ([hash]) => {
  const id = String(hash || '').replace(/^#/, '')
  if (!props.holdScroll || !id || id === hashDone) return
  if (!props.rows.some((m) => String(m.msg_id) === id)) return
  hashDone = id
  await nextTick()
  const el = root.value?.querySelector<HTMLElement>(`[data-msg-id="${CSS.escape(id)}"]`)
  const scroller = el?.closest<HTMLElement>('.feed-body')
  /* newest last: the linked row wins over following the bottom (A9) */
  if (el) hold()
  if (el && scroller) scrollRowToTop(scroller, el)
  el?.focus({ preventScroll: true })
}, { immediate: true })

function openable(m: SpoolMessage) {
  if (props.openButton) return Boolean(m.task_id)
  return Boolean(m.task_id && props.currentTaskId && m.task_id !== props.currentTaskId)
}

/* The row the open topic is rooted at stays selected. The title in the
   right pane is selected as well, so selecting that pane does not clear this row. */
function isSelected(m: SpoolMessage) {
  return Boolean(props.clickable) && isSelectedRow(m, topic.target)
}
</script>

<style scoped>
/* Newest last (topic c6994436): the mirror of main.css .prepend-* - a new
   row rises from below; the pill sticks to the bottom edge of the feed. */
.append-enter-active { transition: transform .22s ease-out, opacity .22s ease-out; }
.append-enter-from { transform: translateY(12px); opacity: 0; }
.append-move { transition: transform .22s ease-out; }
/* A row the window drops sits at the TOP here. TransitionGroup would keep it
   in the flow for one more frame (a leave with no duration), after the anchor
   has measured, and the view would jump by its height: out of the flow now. */
.append-leave-active { display: none; }
@media (prefers-reduced-motion: reduce) {
  .append-enter-active, .append-move { transition: none; }
}
.new-pill-wrap--bottom { top: auto; bottom: 8px; align-items: flex-end; }
</style>
