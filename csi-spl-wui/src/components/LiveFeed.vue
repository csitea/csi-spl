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
        <!-- Spec 061 3.6 (lane L10): a reused agent id - the previous
             holder's messages sit on the far side of this line. -->
        <div
          v-else-if="it.seat"
          class="new-divider seat-divider"
          data-testid="seat-divider"
          role="separator"
          :aria-label="seatLabel"
        >
          <span class="new-divider__label">{{ seatLabel }}</span>
        </div>
        <!-- HUM-10 (owner, t1 topics 6fc56905 / 3e073a95): replies this
             viewer hid by a swipe left (this device only). One thicker line
             stands where a run of them was; a tap shows them again. -->
        <button
          v-else-if="it.hidden"
          type="button"
          class="hidden-cards-line"
          data-testid="hidden-cards-line"
          :data-hidden-ids="it.hidden.join(' ')"
          :aria-label="t('feed.hidden_show', { n: it.hidden.length }, it.hidden.length)"
          :title="t('feed.hidden_show', { n: it.hidden.length }, it.hidden.length)"
          @click="hiddenCards.show(it.hidden)"
        >
          <span class="hidden-cards-line__bar" aria-hidden="true" />
        </button>
        <MessageCard
          v-else-if="it.msg"
          :msg="it.msg"
          :posinset="it.i + 1"
          :setsize="hasOlder ? -1 : shown.length"
          :topic-link="openable(it.msg)"
          :count="countFor && countedRow(it.msg) ? countFor(String(it.msg.task_id || '')) : 0"
          :unread="unreadFor && countedRow(it.msg) ? unreadFor(String(it.msg.task_id || '')) : 0"
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
    <!-- Phone thread only: one round arrow. Away from the newest end it
         jumps there; at that end it jumps to the oldest. -->
    <button
      v-if="phone && props.holdScroll && jumpEnds.show"
      type="button"
      class="thread-jump"
      data-testid="thread-jump"
      :data-end="jumpEnds.show"
      :data-dir="jumpEnds.dir"
      :aria-label="t(jumpEnds.show === 'newest' ? 'feed.new_pill_label' : 'feed.jump_oldest')"
      @click="jumpThreadEnd"
    >
      <UiIcon :name="jumpEnds.dir === 'up' ? 'chevron-up' : 'chevron-down'" :size="22" />
    </button>
    <!-- A #msg near the end of the thread cannot reach the top of the pane
         unless a viewport of room follows it. Kept while that hash is open. -->
    <div v-if="landTail" data-land-tail aria-hidden="true" :style="{ height: landTail + 'px' }" />
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
import { threadJumpState } from '~/utils/thread-jump.mjs'
import { countUnread, firstUnreadId, isUnread } from '~/utils/read-cursor.mjs'
import { seatDividerId } from '~/utils/seat-divider.mjs'
import { collapseHiddenRuns } from '~/utils/hidden-cards.mjs'
import { useHiddenCards } from '~/composables/useHiddenCards'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { isViewersOwn } from '~/utils/typed-by.mjs'
import { useCardClip, type CardClipPane } from '~/composables/useCardClip'
import { useViewPrefs } from '~/composables/useViewPrefs'
import { displayOrder } from '~/utils/view-prefs.mjs'
import { useMobileStack } from '~/composables/useMobileStack'
import { perfDelivered, perfFeed, perfFeedState, perfOn, perfWatchRouter } from '~/utils/perf-mark.mjs'

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
  /** Only this row carries the reply count (a thread pane: its first message, not every reply). */
  countMsgId?: string
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
  /** Spec 061 3.6 (lane L10): when a DM peer's reused agent id was seated by
      its current holder (view-v1 §4.1 boxes[].seated_at). The "new holder
      since" divider goes before that holder's first message. '' = none. */
  seatedAt?: string
}>()
defineEmits<{ older: [], 'clear-search': [], 'open-topic': [msg: SpoolMessage], edited: [msg: SpoolMessage], deleted: [msg: SpoolMessage], reacted: [update: ReactionUpdate] }>()

const { t } = useI18n({ useScope: 'global' })
const topic = useTopicStore()
const people = useHumanNames()
const { mode: clipMode } = useCardClip(props.clipPane)
function countedRow(msg: SpoolMessage) {
  return !props.countMsgId || msg.msg_id === props.countMsgId
}
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

/* Spec 061 3.6 (lane L10): the first message of a reused id's current holder. */
const seatId = computed(() => (props.seatedAt ? seatDividerId(shown.value, props.seatedAt) : ''))
const seatLabel = computed(() => t('feed.seat_divider', { when: isoDateTime(props.seatedAt || '') }))

/* The rows with the dividers interleaved (one keyed element per iteration).
   Each divider sits on the older side of its message: before it newest-last,
   after it newest-first. */
type FeedItem = { key: string, divider?: true, seat?: true, hidden?: string[], msg?: SpoolMessage, i: number }
/* HUM-10: a thread folds the replies hidden on this device (swipe left) */
const hiddenCards = useHiddenCards()
const feedItems = computed<FeedItem[]>(() => {
  const items = feedRows.value
  if (!props.holdScroll || !hiddenCards.ids.value.length) return items
  return collapseHiddenRuns(items, hiddenCards.isHidden) as FeedItem[]
})
const feedRows = computed<FeedItem[]>(() => {
  const out: FeedItem[] = []
  const fid = firstNewId.value
  const sid = seatId.value
  shown.value.forEach((m, i) => {
    const before: FeedItem[] = []
    if (sid && m.msg_id === sid) before.push({ key: '__seat-divider__', seat: true, i: -1 })
    if (fid && m.msg_id === fid) before.push({ key: '__new-divider__', divider: true, i: -1 })
    const card: FeedItem = { key: String(m.msg_id), msg: m, i }
    if (newestLast.value) out.push(...before, card)
    else out.push(card, ...before.reverse())
  })
  return out
})

/* The jump button shows only while the divider is off screen (scrolled away).
   Visibility is measured on scroll with getBoundingClientRect — deliberately
   not an observer (load-more-30 keeps the feed free of auto-load-on-scroll). */
const dividerVisible = ref(false)
/* CLE-77905 (owner, t1 05e24244, 2026-10-01: "Just remove it for now"): NOT on
   a phone. It was meant to take the reader to the first unread message
   (CLE-77804), but in newest-first the unread sit at the top, so it showed
   "1 new" over the top card while the reader was already there - its jump to
   top 0 moved nothing and the pill kept catching taps. Bring it back on
   phones only once it has a target the reader is not already looking at. */
const phone = useMobileStack().isMobile
const showUnreadJump = computed(() => !phone.value && newCount.value > 0 && !pill.value && !dividerVisible.value)
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
  if (phone.value && props.holdScroll) measureJump()
}

/* Phone thread. The scroller is the pane's .feed-body. A channel feed never
   passes holdScroll, and a desktop is not phone, so this stays empty there. */
const jumpEnds = ref(threadJumpState())
/* The phone pane is display:none until the stack shows it, so the first
   measure sees clientHeight 0. A size change (the pane appearing, the
   keyboard, a late picture) measures again. It never asks for another page. */
let jumpResize: ResizeObserver | null = null
let jumpWatched: HTMLElement | null = null
function watchJumpSize(s: HTMLElement) {
  if (typeof ResizeObserver === 'undefined') return
  if (!jumpResize) jumpResize = new ResizeObserver(() => measureJump())
  if (jumpWatched === s) return
  jumpResize.disconnect()
  jumpWatched = s
  jumpResize.observe(s)
}
function measureJump() {
  if (!phone.value || props.holdScroll !== true) {
    if (jumpEnds.value.show) jumpEnds.value = threadJumpState()
    jumpResize?.disconnect()
    jumpWatched = null
    return
  }
  const s = root.value?.closest<HTMLElement>('.feed-body')
  if (!s) return
  watchJumpSize(s)
  const next = threadJumpState({
    scrollTop: s.scrollTop,
    scrollHeight: s.scrollHeight,
    clientHeight: s.clientHeight,
    newestLast: newestLast.value,
  })
  const cur = jumpEnds.value
  if (cur.show !== next.show || cur.dir !== next.dir || cur.top !== next.top) jumpEnds.value = next
}
function jumpThreadEnd() {
  const s = root.value?.closest<HTMLElement>('.feed-body')
  const st = jumpEnds.value
  if (!s || !st.show) return
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
  s.scrollTo({ top: st.top, behavior: reduce ? 'auto' : 'smooth' })
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
  void nextTick(() => measureJump())
})
watch([phone, newestLast, () => props.holdScroll, () => props.rows.length], async () => {
  await nextTick()
  measureJump()
})
onUnmounted(() => {
  if (typeof document !== 'undefined') document.removeEventListener('scroll', onFeedScroll, { capture: true })
  jumpResize?.disconnect()
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
   document itself does not scroll. A row near the end needs room after it
   (`landTail`) or the pane stops short and leaves the row down the list. */
const route = useRoute()
const landTail = ref(0)
let hashDone = ''
watch(() => [route.hash, props.rows.length] as const, async ([hash]) => {
  const id = String(hash || '').replace(/^#/, '')
  if (!props.holdScroll || !id || id === hashDone) return
  if (!props.rows.some((m) => String(m.msg_id) === id)) return
  for (let i = 0; i < 8; i++) {
    await nextTick()
    const el = root.value?.querySelector<HTMLElement>(`[data-msg-id="${CSS.escape(id)}"]`)
    const scroller = el?.closest<HTMLElement>('.feed-body')
    if (!el || !scroller || scroller.clientHeight <= 0) {
      await new Promise((r) => requestAnimationFrame(r))
      continue
    }
    landTail.value = scroller.clientHeight
    await nextTick()
    /* newest last: the linked row wins over following the bottom (A9).
       Focus first: a focus that still scrolls the pane is then corrected. */
    hold()
    el.focus({ preventScroll: true })
    scrollRowToTop(scroller, el)
    hashDone = id
    requestAnimationFrame(() => { scrollRowToTop(scroller, el) })
    return
  }
}, { immediate: true })

/* Spec 066 L6: the timings that end on this feed's paint - M2 the page
   load's first messages, M3 an own send confirmed, M5 a view switch - and M4
   a live row from someone else. A no-op with RUM off. The view key of a
   thread is its topic; of any other feed, its page. */
const perfState = perfFeedState()
perfWatchRouter(useRouter())
watch(() => [props.rows, props.loading, props.label, props.currentTaskId, route.path] as const, () => {
  const thread = props.holdScroll === true
  perfFeed(perfState, {
    rows: props.rows,
    loading: props.loading === true,
    key: thread ? `t|${props.currentTaskId || ''}` : `p|${route.path}|${props.label}`,
    path: route.path,
    thread,
    own: isOwn,
  })
}, { immediate: true })
watch(() => props.lastLive, (m) => {
  if (m && perfOn() && !isOwn(m) && props.rows.some((r) => r.msg_id === m.msg_id)) perfDelivered(m)
})

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
/* HUM-10: the thicker line where hidden replies are; the whole strip is the
   tap target (a phone thumb), the bar inside it is what shows */
.hidden-cards-line {
  display: flex;
  align-items: center;
  width: 100%;
  min-height: 24px;
  padding: 0 12px;
  border: 0;
  background: transparent;
  cursor: pointer;
}
.hidden-cards-line__bar {
  flex: 1;
  height: 4px;
  border-radius: var(--radius-pill);
  background: var(--color-muted);
}
.hidden-cards-line:hover .hidden-cards-line__bar,
.hidden-cards-line:focus-visible .hidden-cards-line__bar { background: var(--color-accent); }
.hidden-cards-line:focus-visible { outline: 2px solid var(--color-accent); outline-offset: -2px; }
.new-pill-wrap--bottom { top: auto; bottom: 8px; align-items: flex-end; }
/* Above the dock and the keyboard. The rule exists only at the phone width. */
@media (max-width: 820px) {
  .thread-jump {
    position: fixed;
    z-index: 15;
    inset-inline-end: 16px;
    bottom: calc(12px + var(--kb-inset, 0px) + max(var(--composer-dock-h, 0px), env(safe-area-inset-bottom, 0px)));
    width: var(--tap, 44px);
    height: var(--tap, 44px);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    border: 1px solid var(--color-border);
    border-radius: 50%;
    background: var(--color-surface);
    color: var(--color-fg);
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.22);
    cursor: pointer;
  }
  .thread-jump:focus-visible { outline: 2px solid var(--color-accent); outline-offset: 2px; }
}
</style>
