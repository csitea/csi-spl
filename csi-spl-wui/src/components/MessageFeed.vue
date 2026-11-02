<template>
  <!-- 8f588edd: the channel's topics-list area (the scroller, so the empty
       space below the cards counts) is a drop zone - a reply dragged here, not
       onto a card, is PROMOTED into a new topic of its own. A card under the
       pointer keeps its own data-move-drop="card" (a MOVE); only a real channel
       (not a DM / lobby / issues) offers it. -->
  <div
    ref="scrollerEl"
    class="feed-body"
    :data-move-drop="promotable ? 'topics' : undefined"
    :data-move-id="promotable && promoteDrag ? 'promote' : undefined"
    :data-move-ok="promotable && promoteDrag ? 'true' : undefined"
  >
    <!-- SPL-1839: one plain sentence + Try again; the technical part only with the Debug pane on (own box: a bare lazy v-if threw insertBefore in #lobby) -->
    <div v-if="channel.error" class="plain-err-slot">
      <LazyPlainErrorNotice :message="channel.error" retry source="channel" test-id="channel-error" @retry="channel.refresh()" />
    </div>
    <!-- spec 150 B6 (panel D1): a sort or New covers the loaded pages only; the line says so while an older page exists -->
    <p v-if="windowLine" class="topic-list-window" data-testid="topic-list-window">{{ windowLine }}</p>
    <!-- SPL-2146: `virtual` - from 120 rows on, only the rows near the
         viewport are drawn; a ?topic= card or the unread divider is drawn
         when asked for (useFeedWindow). -->
    <LiveFeed
      :label="label"
      :rows="listRows"
      :has-older="channel.hasOlder"
      :loading="channel.loading"
      :failed="!!channel.error"
      :search="channel.search"
      :last-live="channel.lastLive"
      :count-for="channel.repliesFor"
      :unread-for="channel.unreadFor"
      :await-for="awaitFor"
      :unread-boundary="boundary"
      :seated-at="seatedAt"
      always-topic
      clickable
      open-button
      clip
      virtual
      :loading-older="channel.loadingOlder"
      @older="channel.loadOlder()"
      @clear-search="channel.setSearch('')"
      @open-topic="openRow"
      @edited="onEdited"
    >
      <!-- SPL-2141: a channel with no messages (or none matching its filter)
           invites the first post; a DM keeps its own Message button. The div
           holds the lazy component (a bare lazy v-if threw insertBefore). -->
      <template v-if="newEmpty" #empty>
        <p class="topic-list-empty-new" data-testid="topic-list-empty-new">{{ t('feed.topic_list.empty_new') }}</p>
      </template>
      <template v-else-if="!channel.peer" #empty="{ search }">
        <div class="feed-empty-slot"><LazyFeedEmpty :channel="channel.active || ''" :search="search" /></div>
      </template>
    </LiveFeed>
    <!-- ?topic= scrolls that card to the top. A card near the end of the
         list needs a viewport of room after it or the pane cannot get there. -->
    <div v-if="tailPx" data-land-tail aria-hidden="true" :style="{ height: tailPx + 'px' }" />
  </div>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useTopicStore } from '~/stores/topic'
import { useTopicRoute } from '~/composables/useTopicRoute'
import { useViewPrefs } from '~/composables/useViewPrefs'
import { useChannelAwait } from '~/composables/useAwaitReply'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { useMove } from '~/composables/useMove'
import { useTopicListChoice } from '~/composables/useTopicListChoice'
import { useTopicCardNew } from '~/composables/useTopicCardNew'
import { topicListView } from '~/utils/topic-list-order.mjs'
import { isPromoteDropTarget, moveBlocked } from '~/utils/move.mjs'
import type { SpoolMessage } from '~/types/spool'

/* 013 on /channel and /dm (X3): the lobby's LiveFeed over the channel store, newest first. */
/* CLE-77804: the page snapshots the read cursor at open (before markRead advances
   it) and passes it here so LiveFeed can draw the New-messages divider. */
/* Spec 061 3.6 (lane L10): a DM with a reused agent id passes the current
   holder's seat time, for LiveFeed's "new holder since" divider. */
const props = defineProps<{ label: string, boundary?: { ts: string, id: string } | null, seatedAt?: string }>()
const channel = useChannelStore()
const { t } = useI18n({ useScope: 'global' })
const topic = useTopicStore()
/* SPL-1994: a topic row waits (hourglass) while its topic does */
const awaitFor = useChannelAwait()

/* 8f588edd: promote-by-drag is offered only on a real channel (not a DM,
   lobby or issues), and the background lights up only while a reply is being
   dragged (a message drag). */
const move = useMove()
const promotable = computed(() => !channel.peer && !moveBlocked(channel.active))
const promoteDrag = computed(() => isPromoteDropTarget(move.drag.value))

/* the same message can be on screen in the feed AND as the pinned
   root of the 3rd panel, so every store that may hold it is told. */
const { applyEverywhere, viewerId } = useMessageEdit()

/* Spec 150 B6: the header's filter and sort (useTopicListChoice) over the
   loaded topic cards. New keeps the cards LiveFeed's unread order ranks by
   (cardNew.unseen, C210); the defaults (All, Last update) hand LiveFeed
   today's rows untouched. The priority is the hub's, on the topic totals. */
const choice = useTopicListChoice()
const cardNew = useTopicCardNew(() => props.boundary, viewerId, { countFor: channel.repliesFor, unreadFor: channel.unreadFor })
const listRows = computed(() => {
  const rows = channel.newestFirst
  if (!choice.filtered.value && !choice.sorted.value) return rows
  return topicListView(rows, {
    filter: choice.filter.value,
    sort: choice.sort.value,
    unreadOf: (m: SpoolMessage) => cardNew.unseen(m),
    countOf: (m: SpoolMessage) => channel.repliesFor(String(m.task_id || '')),
    priorityOf: (m: SpoolMessage) => channel.priorityFor(String(m.task_id || '')),
  })
})
const windowLine = computed(() => {
  if (!channel.hasOlder) return ''
  const n = channel.newestFirst.length
  if (choice.filtered.value) return t('feed.topic_list.window_new', { n })
  return choice.sorted.value ? t('feed.topic_list.window', { n }) : ''
})
const newEmpty = computed(() => choice.filtered.value && channel.newestFirst.length > 0)

function onEdited(row: SpoolMessage) {
  applyEverywhere(row)
}

/* a click anywhere on a row opens its topic in the pane and puts
   it in the URL. Every row here is a topic root of its own (the feed is
   rootsByTask), so this is the task-rooted case the pane already handled —
   what is new is that the whole row does it, that it works from the keyboard,
   and that a reload comes back to the same topic. */
const { openRow } = useTopicRoute({
  open: (target, root) => topic.openTarget(target, root),
  close: () => topic.close(),
  rowFor: (msgId) => channel.messages.find((m) => m.msg_id === msgId) as SpoolMessage | undefined,
})

/* A pasted or written id opens /channel/<name>?topic=<task> (or the direct
   message twin). The menu path scrolls that card; a plain link did not.
   The tail is a viewport of room after the last card so the named card can
   sit at the top of this pane, and it stays while ?topic= is in the address. */
const scrollerEl = ref<HTMLElement | null>(null)
const tailPx = ref(0)
if (import.meta.client) {
  const route = useRoute()
  const router = useRouter()
  const { newestLast } = useViewPrefs()
  let landGen = 0
  /* SPL-2150: the tail follows the pane's height after landing */
  let unfollow = () => {}
  onBeforeUnmount(() => unfollow())
  async function landTopic() {
    const gen = ++landGen
    unfollow()
    unfollow = () => {}
    const raw = route.query.topic
    const taskId = String(Array.isArray(raw) ? raw[0] : raw || '')
    if (!taskId) {
      tailPx.value = 0
      return
    }
    await nextTick()
    await new Promise((r) => requestAnimationFrame(r))
    if (gen !== landGen) return
    const el = scrollerEl.value
    if (el && el.clientHeight > 0) tailPx.value = el.clientHeight
    await nextTick()
    if (gen !== landGen) return
    const hash = String(route.hash || '')
    const m = await import('~/utils/parent-section-open.mjs')
    if (gen !== landGen) return
    if (typeof m.scrollTopicCard === 'function') {
      await m.scrollTopicCard({ router, newestLast: newestLast.value, taskId, hash, alive: () => gen === landGen })
    }
    if (gen !== landGen || typeof m.followTopicPane !== 'function') return
    unfollow = m.followTopicPane({
      scroller: scrollerEl.value,
      taskId,
      newestLast: () => newestLast.value,
      setTail: (h) => { tailPx.value = h; return nextTick() },
    })
  }
  watch(() => {
    const raw = route.query.topic
    const id = Array.isArray(raw) ? raw[0] : raw
    return String(id || '')
  }, () => { void landTopic() }, { immediate: true })
  /* SPL-4624: a topic closed while its landing waits for the card stays closed.
     The route's drop of ?topic= is still in flight, so the watch above moves
     too late: the landing opened it again and level 3 was pushed over the same
     page, and the next phone Back looked dead. */
  watch(() => topic.open, (open) => { if (!open) landGen++ }, { flush: 'sync' })
}
</script>

<style scoped>
.topic-list-window,
.topic-list-empty-new {
  margin: 4px 12px;
  font-size: 0.8125rem;
  color: var(--color-muted);
}
</style>
