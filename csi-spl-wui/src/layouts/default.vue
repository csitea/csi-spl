<!-- App frame, shaped like the donor WUI's layouts/default.vue: one contained
     .layout box (no document x-scroll), the page content, and the gated
     diagnostics panel LAST so the most recent technical error is literally the
     bottom-most content of the page. The spool shell (sidebar, feed, topic
     panes) stays client-only: it reads sessionStorage/localStorage and opens
     the live socket. Vertical pane dividers are pointer+keyboard resizers.
     022: the persistent top bar (Omnibox, language switcher, user menu) sits
     above the 3-pane shell, which fills the rest of the viewport.
     CLE-3429: exactly ONE topic section at a time (1..1) — see below.
     SPL-989: at <= 820 px ONE panel of the three shows (useMobileStack);
     data-mobile-level is what main.css reads, above 820 px nothing does. -->
<template>
  <div class="layout">
    <ClientOnly>
      <div class="app-frame">
      <TopBar />
      <div
        class="spool-shell"
        style="max-width:100%;min-width:0"
        :style="shellStyle"
        :data-mobile-level="stack.level.value"
        :data-mobile-topic="topicPaneOpen ? '1' : undefined"
        @pointerdown.capture="paneFocus.noteEvent"
        @focusin="paneFocus.noteEvent"
        @touchstart.passive="stack.swipe.onTouchStart"
        @touchend.passive="stack.swipe.onTouchEnd"
      >
        <ChannelSidebar />
        <PaneDivider
          v-if="showSidebarDivider"
          pane="sidebar"
          :value="displayed.sidebar"
          :min="sidebarBounds.min"
          :max="sidebarBounds.max"
          @input="setSidebar"
          @reset="resetSidebar"
        />
        <main class="spool-main">
          <slot />
          <!-- topic c6994436 (lane B): the bottom Omnibox dock - under the
               MIDDLE pane only. TopBar teleports its one composer here when
               Settings -> Behaviour says "at the bottom" (never on a phone).
               Always in the tree, so the Teleport has a target to move to;
               it takes no room while empty. -->
          <div
            :id="DOCK_ID"
            ref="dockEl"
            class="omnibox-dock"
            data-test="omnibox-dock"
            :data-on="dockOn ? 'true' : undefined"
          />
        </main>
        <PaneDivider
          v-if="topicPaneOpen && showTopicDivider"
          pane="topic"
          :value="displayed.topic"
          :min="topicBounds.min"
          :max="topicBounds.max"
          @input="setTopic"
          @reset="resetTopic"
        />
        <!-- CLE-3429 (1..1): ONE topic section, whichever store holds it.
             This v-if / v-else chain is the structural half of the invariant —
             the two panes can never both be in the tree, on any route, theme or
             width. Do NOT mount either of them a second time: utils/topic-pane
             is the only place allowed to decide which one renders. -->
        <LiveTopicPane v-if="section === LIVE" />
        <TopicPane v-else-if="section === CHANNEL" />
      </div>
      </div>
      <template #fallback>
        <div class="login"><p class="muted">{{ $t('app.loading') }}</p></div>
      </template>
    </ClientOnly>
    <!-- Renders only for a human who ticked "Debug pane" in Settings →
         Appearance (session claim `diagnostics_enabled`); for everyone else the v-if inside contributes
         no markup at all. <ClientOnly> keeps it out of the prerendered bundle. -->
    <ClientOnly>
      <ErrorSnackbar />
    </ClientOnly>
    <!-- SPL-1024: "Moved to ... · Undo"; its chunk loads on the first move only -->
    <ClientOnly>
      <LazyMoveUndoToast v-if="move.toast.value" />
    </ClientOnly>
    <ClientOnly>
      <DebugPanel />
    </ClientOnly>
  </div>
</template>

<script setup lang="ts">
import { usePaneFocus } from '~/stores/pane-focus'
/* which pane the reader selected last decides where the Omnibox line goes */
const paneFocus = usePaneFocus()
import DebugPanel from '@/components/common/DebugPanel.vue'
import ErrorSnackbar from '@/components/common/ErrorSnackbar.vue'
import TopBar from '@/components/TopBar.vue'
import { useTopicStore } from '~/stores/topic'
import { useLiveFeed } from '~/stores/live'
import { usePaneWidths } from '~/composables/usePaneWidths'
import { CHANNEL, LIVE, NONE, closes, topicSection } from '~/utils/topic-pane.mjs'
import { useLive } from '~/composables/useLive'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { topicFrameDrops, topicFrameRows, topicFrameTasks } from '~/utils/topic-archive.mjs'
import { useViewerStore } from '~/stores/viewer'
import { useMobileStack } from '~/composables/useMobileStack'
import { useOmniboxDock } from '~/composables/useOmniboxDock'
import { DOCK_ID } from '~/utils/omnibox-dock.mjs'
import { useMove } from '~/composables/useMove'

const topic = useTopicStore()
/* topic c6994436: the bottom dock under the middle pane is on */
const dockOn = useOmniboxDock()
/* its height, for the panes that overlay the middle one (main.css). A ref,
   not onMounted: <ClientOnly> renders the shell after this layout mounts. */
const dockEl = ref<HTMLElement | null>(null)
let dockObserver: ResizeObserver | null = null
function dockHeight() {
  const el = dockEl.value
  const px = dockOn.value && el ? Math.round(el.getBoundingClientRect().height) : 0
  document.documentElement.style.setProperty('--omnibox-dock-h', `${px}px`)
}
watch(dockEl, (el) => {
  dockObserver?.disconnect()
  dockObserver = null
  if (el && typeof ResizeObserver !== 'undefined') {
    dockObserver = new ResizeObserver(dockHeight)
    dockObserver.observe(el)
  }
  dockHeight()
})
watch(dockOn, () => { void nextTick(dockHeight) })
onUnmounted(() => {
  dockObserver?.disconnect()
  document.documentElement.style.removeProperty('--omnibox-dock-h')
})
const livePane = useLiveFeed('pane')
/* A delete from another tab drops the row from every store this shell holds. */
const live = useLive()
const { dropEverywhere } = useMessageEdit()
/* SPL-1024: another tab's topic_moved / message_moved frame moves the rows here too */
const move = useMove()
let offDeleted = () => {}
let offTopic = () => {}
/* SPL-996: a focusin chooses a pane only right after the reader's own
   navigation key (stores/pane-focus.ts); capture, so a handler that stops
   the key cannot hide it */
const noteKey = (ev: KeyboardEvent) => paneFocus.noteKey(ev)
onMounted(() => {
  document.addEventListener('keydown', noteKey, true)
  offDeleted = live.onDeleted((m) => dropEverywhere(String(m.msg_id || '')))
  /* SPL-983: an archived card leaves the feeds; a deleted topic takes every
     row, and a pane open on one of its tasks has nothing left to show. */
  offTopic = live.onTopic((f) => {
    for (const id of topicFrameDrops(f)) dropEverywhere(id)
    /* SPL-986: and its row leaves the Topics / Flow lists */
    useViewerStore().dropTopics(topicFrameRows(f, live.lobbyTaskId.value))
    const gone = topicFrameTasks(f, live.lobbyTaskId.value)
    if (livePane.taskId && gone.includes(String(livePane.taskId))) livePane.close()
    if (topic.open && gone.includes(String(topic.parentTaskId || ''))) topic.close()
    move.dispatch(f)
  })
})
onUnmounted(() => { offDeleted(); offTopic(); document.removeEventListener('keydown', noteKey, true) })
/* the single source of truth for which topic section is on screen. */
const section = computed(() => topicSection({ paneTaskId: livePane.taskId, topicOpen: topic.open }))
const topicPaneOpen = computed(() => section.value !== NONE)

/* SPL-989: the phone stack. Level 3 follows either topic store; Back from it
   closes whichever is open, exactly as the pane's own Close does. */
const stack = useMobileStack()
stack.install({
  topicOpen: topicPaneOpen,
  closeTopic: () => { livePane.close(); topic.close() },
})

/* CLE-3429, the state half of 1..1: opening one section closes the other, so
   the section the reader opened LAST is the one they see. Without this a stale
   live pane would outrank a freshly opened channel topic and the click would
   look dead. `flush: 'sync'` so the losing store is cleared before the render
   that would otherwise show the wrong pane for one frame. Neither watcher can
   re-trigger the other: closing only ever writes the falsy side. */
watch(() => livePane.taskId, (id) => {
  if (id && closes(LIVE, { topicOpen: topic.open }) === CHANNEL) topic.close()
}, { flush: 'sync' })
watch(() => topic.open, (open) => {
  if (open && closes(CHANNEL, { paneTaskId: livePane.taskId }) === LIVE) livePane.close()
}, { flush: 'sync' })

const {
  displayed,
  sidebarBounds,
  topicBounds,
  showSidebarDivider,
  showTopicDivider,
  shellStyle,
  setSidebar,
  setTopic,
  resetSidebar,
  resetTopic,
} = usePaneWidths({ topicOpen: topicPaneOpen })
</script>

<style scoped>
.layout {
  max-width: 100%;
  min-width: 0;
  height: 100%;
  max-height: 100%;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}
</style>
