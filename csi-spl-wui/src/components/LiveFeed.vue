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
      <!-- CLE-77804: jump to the New-messages divider when it is scrolled away. -->
      <button v-if="showUnreadJump" class="btn new-pill" type="button" :aria-label="t('feed.unread_jump_label')" data-testid="unread-jump" @click="jumpToUnread">
        ↑ {{ t('feed.unread_jump', { n: newCount }) }}
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
    <TransitionGroup :name="newestLast ? 'append' : 'prepend'" tag="div" class="live-rows" :data-order="newestLast ? 'newest-last' : undefined">
      <!-- CLE-77804 (topic 1e7d56b8): feedItems interleaves the "New messages"
           divider with the rows so each iteration renders exactly ONE keyed
           element (the key lives on the <template>, as Vue requires). The
           divider marks where the unread block starts: newest-last reads top to
           bottom so it sits BEFORE the earliest unread; newest-first has the
           unread at the top, so it sits AFTER it. -->
      <template v-for="it in feedItems" :key="it.key">
        <div
          v-if="it.divider"
          class="new-divider"
          data-testid="new-divider"
          role="separator"
          :aria-label="t('feed.unread_divider')"
        >
          <span class="new-divider__label">{{ t('feed.unread_divider') }}</span>
        </div>
        <MessageCard
          v-else-if="it.msg"
          :msg="it.msg"
          :posinset="it.i + 1"
          :setsize="hasOlder ? -1 : shown.length"
          :topic-link="openable(it.msg)"
          :count="countFor ? countFor(String(it.msg.task_id || '')) : 0"
          :unread="unreadFor ? unreadFor(String(it.msg.task_id || '')) : 0"
          :always-topic="alwaysTopic"
          :clickable="clickable"
          :selected="isSelected(it.msg)"
          :since-ms="sinceMs"
          :editable="canEdit(it.msg)"
          :merge-prev="mergeTarget(it.msg, 'previous')"
          :merge-next="mergeTarget(it.msg, 'next')"
          :current-task-id="currentTaskId"
          :clip-mode="clipModeFor()"
          :topic-menu="openButton"
          :move-ctx="moveCtx"
          :class="{ pending: it.msg.pending, 'msg--new': isNew(it.msg) }"
          :data-key="it.msg.msg_id"
          :data-pending="it.msg.pending ? 'true' : undefined"
          :data-unread="isNew(it.msg) ? 'true' : undefined"
          @open-topic="(row: SpoolMessage) => $emit('open-topic', row)"
          @edited="(row: SpoolMessage) => $emit('edited', row)"
          @deleted="(row: SpoolMessage) => $emit('deleted', row)"
          @reacted="(update: ReactionUpdate) => $emit('reacted', update)"
        />
      </template>
    </TransitionGroup>
    <p v-if="!loading && !rows.length" class="muted empty">{{ search ? t('feed.no_matches') : (emptyText || t('feed.empty')) }}</p>
    <div v-if="newestLast" class="new-pill-wrap new-pill-wrap--bottom">
      <button v-if="showUnreadJump" class="btn new-pill" type="button" :aria-label="t('feed.unread_jump_label')" data-testid="unread-jump" @click="jumpToUnread">
        ↓ {{ t('feed.unread_jump', { n: newCount }) }}
      </button>
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
import { pendingDeleteId } from '~/composables/useDeleteUndo'
import type { ReactionUpdate, SpoolMessage } from '~/types/spool'
import { useScrollAnchor } from '~/composables/useScrollAnchor'
import { useTopicStore } from '~/stores/topic'
import { isSelectedRow } from '~/utils/topic-open.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { mergeableSourceIn, neighborIn, threadNeighbors } from '~/utils/msg-menu.mjs'
import { useLive } from '~/composables/useLive'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { countUnread, firstUnreadId, isUnread } from '~/utils/read-cursor.mjs'
import { isViewersOwn } from '~/utils/typed-by.mjs'
import { useCardClip, type CardClipPane } from '~/composables/useCardClip'
import { useViewPrefs } from '~/composables/useViewPrefs'
import { displayOrder } from '~/utils/view-prefs.mjs'

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
  /** CLE-77804 (topic 35053f95): the reader's unread reply count per topic. */
  unreadFor?: (taskId: string) => number
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
  /** CLE-77804 (topic 1e7d56b8): the read cursor frozen when this feed was
      opened. Messages after it are "new": the divider goes before the first,
      they carry a fading highlight, and a "N new" button jumps to the divider.
      null / undefined (a never-read feed, or a pane that opts out) shows none. */
  unreadBoundary?: { ts: string, id: string } | null
}>()
defineEmits<{ older: [], 'clear-search': [], 'open-topic': [msg: SpoolMessage], edited: [msg: SpoolMessage], deleted: [msg: SpoolMessage], reacted: [update: ReactionUpdate] }>()

const { t } = useI18n({ useScope: 'global' })
const topic = useTopicStore()
const people = useHumanNames()
const { mode: clipMode } = useCardClip(props.clipPane)
function clipModeFor() {
  return props.clip ? clipMode.value : undefined
}
const root = ref<HTMLElement | null>(null)
const { newestLast } = useViewPrefs()
/* the rows in DOM (= reading) order */
/* CLE-77840: a reply deleted with the Delete key stays hidden while its Undo
   window is open, even if a re-read brings the hub's (not yet deleted) row back */
const shown = computed(() => displayOrder(props.rows.filter((m) => !pendingDeleteId.value || String(m.msg_id || '') !== pendingDeleteId.value), newestLast.value ? 'newest-last' : 'newest-first') as SpoolMessage[])
/* Newest last: a thread follows new replies too while its reader sits at the
   bottom (A6); a reader scrolled up in it is never moved. */
const { pill, jump, hold } = useScrollAnchor(
  root,
  () => shown.value.map((m) => String(m.msg_id)),
  (id) => Boolean(props.rows.find((m) => m.msg_id === id)?.pending),
  () => props.holdScroll !== true || newestLast.value,
  () => newestLast.value,
)

/* CLE-77804: the New-messages divider. `firstNewId` is the earliest message the
   reader had not seen when the feed opened (the boundary is frozen by the page,
   so it stays put while markRead advances the live cursor and clears the badge).
   isNew() drives the fading highlight; newCount the jump button. The reader's
   OWN messages are never new (HUM-24, topic 311427c6): sending one must not
   push it under the divider or bump the "N new" count. */
const { viewerId } = useMessageEdit()
function isOwn(m: SpoolMessage) {
  return isViewersOwn(m, viewerId.value)
}
const firstNewId = computed(() => (props.unreadBoundary ? firstUnreadId(shown.value, props.unreadBoundary, viewerId.value) : ''))
const newCount = computed(() => (props.unreadBoundary ? countUnread(shown.value, props.unreadBoundary, viewerId.value) : 0))
function isNew(m: SpoolMessage) {
  return Boolean(props.unreadBoundary) && !isOwn(m) && isUnread(m, props.unreadBoundary)
}

/* The rows with the divider interleaved (one keyed element per iteration). */
type FeedItem = { key: string, divider?: true, msg?: SpoolMessage, i: number }
const feedItems = computed<FeedItem[]>(() => {
  const out: FeedItem[] = []
  const fid = firstNewId.value
  shown.value.forEach((m, i) => {
    const card: FeedItem = { key: String(m.msg_id), msg: m, i }
    const divider: FeedItem = { key: '__new-divider__', divider: true, i: -1 }
    if (fid && m.msg_id === fid) {
      if (newestLast.value) out.push(divider, card)
      else out.push(card, divider)
    } else {
      out.push(card)
    }
  })
  return out
})

/* The jump button shows only while the divider is off screen (scrolled away).
   Visibility is measured on scroll with getBoundingClientRect — deliberately
   not an observer (load-more-30 keeps the feed free of auto-load-on-scroll). */
const dividerVisible = ref(false)
const showUnreadJump = computed(() => newCount.value > 0 && !pill.value && !dividerVisible.value)
function dividerEl(): HTMLElement | null {
  return root.value?.querySelector<HTMLElement>('[data-testid="new-divider"]') || null
}
function measureDivider() {
  const el = dividerEl()
  if (!el) {
    dividerVisible.value = false
    return
  }
  const scroller = el.closest<HTMLElement>('.feed-body')
  if (!scroller) {
    dividerVisible.value = true
    return
  }
  const er = el.getBoundingClientRect()
  const sr = scroller.getBoundingClientRect()
  dividerVisible.value = er.bottom > sr.top && er.top < sr.bottom
}
function onFeedScroll() {
  if (firstNewId.value) measureDivider()
}

function jumpToUnread() {
  const el = dividerEl()
  const scroller = el?.closest<HTMLElement>('.feed-body')
  if (!scroller) return
  hold()
  /* newest-last: the unread block starts at the divider, read down from there.
     newest-first: the unread sit at the top of the feed — go up to them. */
  if (newestLast.value && el) scrollRowToTop(scroller, el)
  else scroller.scrollTo({ top: 0, behavior: 'auto' })
}

/* On open (a new boundary, once the rows are in) land at the first unread: for
   newest-last that means scrolling the divider to the top (the feed otherwise
   opens at its bottom); newest-first already opens at the top where the newest
   unread are. hold() stops the newest-last bottom glue so this scroll wins, the
   same way a #msg deep link does. Then measure whether the divider is on
   screen for the jump button. */
let dividerDone = ''
watch(() => props.unreadBoundary, () => { dividerDone = '' })
watch(() => [firstNewId.value, props.rows.length] as const, async ([id]) => {
  await nextTick()
  if (id && id !== dividerDone) {
    dividerDone = id
    const el = dividerEl()
    const scroller = el?.closest<HTMLElement>('.feed-body')
    if (el && scroller && newestLast.value) {
      hold()
      scrollRowToTop(scroller, el)
    }
  }
  measureDivider()
}, { immediate: true })

onMounted(() => {
  if (typeof document !== 'undefined') document.addEventListener('scroll', onFeedScroll, { capture: true, passive: true })
})
onUnmounted(() => {
  if (typeof document !== 'undefined') document.removeEventListener('scroll', onFeedScroll, { capture: true })
})

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
