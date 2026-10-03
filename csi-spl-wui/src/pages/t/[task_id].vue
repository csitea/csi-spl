<template>
  <div class="feed-col">
    <header class="feed-header">
      <MobileBack />
      <!-- t1 1d8e647d: the title, one line, never the raw id.
           Phone (≤820 px): the title takes the free width of this one row.
           "Topics /" gives way to the back arrow. The card-height control
           and the status line move into the ⋯ menu. Desktop is unchanged. -->
      <h2 class="topic-page-heading">
        <NuxtLink class="topic-page-crumb" :to="localePath('/')">{{ t('nav.topics') }}</NuxtLink>
        <span class="topic-page-sep" aria-hidden="true">/</span>
        <span
          v-if="heading"
          class="topic-page-title"
          data-test="topic-page-title"
          :title="heading"
          @pointerdown="titlePress.down"
          @pointermove="titlePress.move"
          @pointerup="titlePress.up"
          @pointercancel="titlePress.cancel"
          @click="onTitleClick"
        >{{ heading }}</span>
        <ArchivedBadge v-if="store.archivedAt" :at="store.archivedAt" />
      </h2>
      <span class="muted topic-page-status" :title="statusText">{{ statusText }}</span>
      <!-- SPL-963: the thread's control, as in the right pane. On a phone it
           sits in the overflow with the status, so the title can use the row. -->
      <div class="topic-page-tools" :data-open="toolsOpen ? '1' : undefined">
        <button
          type="button"
          class="icon-btn topic-page-more"
          data-test="topic-page-more"
          :aria-expanded="toolsOpen ? 'true' : 'false'"
          aria-controls="topic-page-tools"
          :aria-label="t('mobile.more')"
          :title="t('mobile.more')"
          @click.stop="toolsOpen = !toolsOpen"
        >
          <UiIcon name="more" :size="22" />
        </button>
        <div id="topic-page-tools" class="topic-page-tools__panel" data-test="topic-page-tools">
          <p class="topic-page-tools__status">{{ statusText }}</p>
          <LazyCardClipControl pane="thread" />
        </div>
      </div>
      <p
        v-if="titleFull && heading"
        class="topic-page-title-full"
        data-test="topic-page-title-full"
        role="tooltip"
      >{{ heading }}</p>
    </header>
    <div class="pinned-root feed-body" data-test="topic-root">
      <ViewTokenForm v-if="store.door" :detail="store.door.detail" @saved="reopen" />
      <ErrorNotice v-if="store.error" :message="store.error" source="topic" test-id="topic-error" />
      <LiveFeed
        clip
        clip-pane="thread"
        hold-scroll
        :label="t('topic.replies_label')"
        :rows="messages"
        :has-older="store.hasOlder"
        :loading-older="store.loadingOlder"
        @older="store.loadOlder()"
        :loading="store.loading"
        :search="store.search"
        :last-live="store.lastLive"
        :since-ms="sinceMs"
        @clear-search="store.setSearch('')"
        @edited="onEdited"
      />
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useLive } from '~/composables/useLive'
import { useTopicStore } from '~/stores/topic'
import { newestFirst } from '~/utils/feed.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import type { SpoolMessage } from '~/types/spool'
import { useSidePane } from '~/composables/useSidePane'
import { useMobileStack } from '~/composables/useMobileStack'
import { isParentFlag, omniboxReplyTaskId, startsNewTopic } from '~/utils/omnibox-topic.mjs'
import { topicTitleFromRows } from '~/utils/view-api.mjs'
import { createLongPress } from '~/utils/touch-ui.mjs'

const route = useRoute()
const store = useLiveFeed('main')
const side = useLiveFeed('pane')
const channel = useChannelStore()
const live = useLive()
const { t, te } = useI18n({ useScope: 'global' })
/* SPL-976: the placeholder names the keys of the person's Behaviour setting */
const { hintFor: sk } = useSubmitKey()
const localePath = useLocalePath()
/** Socket state token (open, reconnecting, …) in words; an unknown token (a config error) shows as is. */
const stateLabel = (s: string) => (te('feed.live_state.' + s) ? t('feed.live_state.' + s) : s)
const statusText = computed(() => t('pages.task.status', { n: store.messages.length, state: stateLabel(live.state.value) }))
/* A phone has no hover. A long-press shows the full title; the title
   attribute is the hover for a desktop pointer. */
const titleFull = ref(false)
const toolsOpen = ref(false)
const titlePress = createLongPress({
  onPress() { titleFull.value = true },
})
function onTitleClick() {
  if (titlePress.takeClick()) return
}
function onDocPointerDown(ev: PointerEvent) {
  const node = ev.target instanceof Node ? ev.target : null
  const header = document.querySelector('.feed-col > .feed-header')
  if (!node || !header || !header.contains(node)) {
    toolsOpen.value = false
    titleFull.value = false
    return
  }
  const more = header.querySelector('[data-test="topic-page-more"]')
  const panel = header.querySelector('[data-test="topic-page-tools"]')
  const title = header.querySelector('[data-test="topic-page-title"]')
  const tip = header.querySelector('[data-test="topic-page-title-full"]')
  if (toolsOpen.value && more && !more.contains(node) && panel && !panel.contains(node)) toolsOpen.value = false
  if (titleFull.value && title && !title.contains(node) && (!tip || !tip.contains(node))) titleFull.value = false
}
function onDocKey(ev: KeyboardEvent) {
  if (ev.key !== 'Escape') return
  toolsOpen.value = false
  titleFull.value = false
}
const taskId = computed(() => String(route.params.task_id || ''))
const shortId = computed(() => taskId.value.slice(0, 8))
/* t1 1d8e647d: the header names the topic by its oldest row. While
   older pages are still loading, a reply must not stand in as the title. */
const heading = computed(() => (store.hasOlder ? '' : topicTitleFromRows(store.messages, null)))
const topic = useTopicStore()
const sidePane = useSidePane()
/* SPL-989: a topic deep link is the phone's level 3; Back steps to the Topics list (level 2) */
useMobileStack().rightPanel(() => true, () => { void navigateTo(localePath('/'), { replace: true }) })
const sinceMs = useNowTick(() => Boolean(taskId.value))
const messages = computed(() => newestFirst(store.newestFirst))

function reopen() {
  if (taskId.value) void store.open(taskId.value, { all: true })
}

onMounted(() => {
  watch(taskId, reopen, { immediate: true })
  document.addEventListener('pointerdown', onDocPointerDown)
  document.addEventListener('keydown', onDocKey)
})
onBeforeUnmount(() => {
  document.removeEventListener('pointerdown', onDocPointerDown)
  document.removeEventListener('keydown', onDocKey)
})

/* an edit landed on this page's own feed store (the live store
   already applies a `message_edited` frame from another session itself). */
const { applyEverywhere } = useMessageEdit()

function onEdited(row: SpoolMessage) {
  applyEverywhere(row)
}

/* Topics tab with this task selected: the omnibox replies here. `in:`
   naming another topic still goes there. A different left tab starts a new message. */
async function onSend(text: string, files?: File[], topicId?: string, channelId?: string) {
  const target = omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: taskId.value,
    namedTopicId: topicId || '',
    paneVisible: true,
    /* SPL-996 B: `@someone` first is the explicit new topic */
    newTopic: startsNewTopic(text),
  })
  if (target && target === taskId.value && store.taskId) {
    await store.send(text, files || [], { isParent: isParentFlag({ paneVisible: true }) })
    return
  }
  const sent = await channel.send(text, target || undefined, files, channelId, isParentFlag({ paneVisible: Boolean(target) }))
  topic.noteBorn(topic.open || Boolean(side.taskId), target, sent as SpoolMessage)
}
function replyTarget() {
  return omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: taskId.value,
    namedTopicId: '',
    paneVisible: true,
  })
}
useOmniboxTarget({
  placeholder: () => (replyTarget() ? t(sk('topic.reply_placeholder')) : t(sk('search.placeholder_target'), { target: shortId.value })),
  dock: () => ({ reply: Boolean(replyTarget()), target: shortId.value }),
  send: onSend,
  busy: () => store.sending,
})
</script>
