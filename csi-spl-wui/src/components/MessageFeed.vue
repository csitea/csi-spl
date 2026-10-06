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
    <ErrorNotice v-if="channel.error" :message="channel.error" source="channel" test-id="channel-error" />
    <LiveFeed
      :label="label"
      :rows="channel.newestFirst"
      :has-older="channel.hasOlder"
      :loading="channel.loading"
      :search="channel.search"
      :last-live="channel.lastLive"
      :count-for="channel.repliesFor"
      :unread-for="channel.unreadFor"
      :unread-boundary="boundary"
      :seated-at="seatedAt"
      always-topic
      clickable
      open-button
      clip
      :loading-older="channel.loadingOlder"
      @older="channel.loadOlder()"
      @clear-search="channel.setSearch('')"
      @open-topic="openRow"
      @edited="onEdited"
    />
    <!-- ?topic= scrolls that card to the top. A card near the end of the
         list needs a viewport of room after it or the pane cannot get there. -->
    <div v-if="tailPx" data-land-tail aria-hidden="true" :style="{ height: tailPx + 'px' }" />
  </div>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useChannelStore } from '~/stores/channel'
import { useTopicStore } from '~/stores/topic'
import { useTopicRoute } from '~/composables/useTopicRoute'
import { useViewPrefs } from '~/composables/useViewPrefs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { useMove } from '~/composables/useMove'
import { isPromoteDropTarget, moveBlocked } from '~/utils/move.mjs'
import type { SpoolMessage } from '~/types/spool'

/* 013 on /channel and /dm (X3): the lobby's LiveFeed over the channel store, newest first. */
/* CLE-77804: the page snapshots the read cursor at open (before markRead advances
   it) and passes it here so LiveFeed can draw the New-messages divider. */
/* Spec 061 3.6 (lane L10): a DM with a reused agent id passes the current
   holder's seat time, for LiveFeed's "new holder since" divider. */
defineProps<{ label: string, boundary?: { ts: string, id: string } | null, seatedAt?: string }>()
const channel = useChannelStore()
const topic = useTopicStore()

/* 8f588edd: promote-by-drag is offered only on a real channel (not a DM,
   lobby or issues), and the background lights up only while a reply is being
   dragged (a message drag). */
const move = useMove()
const promotable = computed(() => !channel.peer && !moveBlocked(channel.active))
const promoteDrag = computed(() => isPromoteDropTarget(move.drag.value))

/* the same message can be on screen in the feed AND as the pinned
   root of the 3rd panel, so every store that may hold it is told. */
const { applyEverywhere } = useMessageEdit()

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
  async function landTopic() {
    const gen = ++landGen
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
      await m.scrollTopicCard({ router, newestLast: newestLast.value, taskId, hash })
    }
  }
  watch(() => {
    const raw = route.query.topic
    const id = Array.isArray(raw) ? raw[0] : raw
    return String(id || '')
  }, () => { void landTopic() }, { immediate: true })
}
</script>
