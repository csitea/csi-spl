<!-- App frame, shaped like the donor WUI's layouts/default.vue: one contained
     .layout box (no document x-scroll), the page content, and the gated
     diagnostics panel LAST so the most recent technical error is literally the
     bottom-most content of the page. The spool shell (sidebar, feed, thread
     panes) stays client-only: it reads sessionStorage/localStorage and opens
     the live socket. Vertical pane dividers are pointer+keyboard resizers.
     022: the persistent top bar (Omnibox, language switcher, user menu) sits
     above the 3-pane shell, which fills the rest of the viewport.
     CLE-3429: exactly ONE thread section at a time (1..1) — see below. -->
<template>
  <div class="layout">
    <ClientOnly>
      <div class="app-frame">
      <TopBar />
      <div
        class="spool-shell"
        style="max-width:100%;min-width:0"
        :style="shellStyle"
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
        </main>
        <PaneDivider
          v-if="threadPaneOpen && showThreadDivider"
          pane="thread"
          :value="displayed.thread"
          :min="threadBounds.min"
          :max="threadBounds.max"
          @input="setThread"
          @reset="resetThread"
        />
        <!-- CLE-3429 (1..1): ONE thread section, whichever store holds it.
             This v-if / v-else chain is the structural half of the invariant —
             the two panes can never both be in the tree, on any route, theme or
             width. Do NOT mount either of them a second time: utils/thread-pane
             is the only place allowed to decide which one renders. -->
        <LiveThreadPane v-if="section === LIVE" />
        <ThreadPane v-else-if="section === CHANNEL" />
      </div>
      </div>
      <template #fallback>
        <div class="login"><p class="muted">{{ $t('app.loading') }}</p></div>
      </template>
    </ClientOnly>
    <!-- Renders only for an identity the operator granted (session claim
         `diagnostics_enabled`); for everyone else the v-if inside contributes
         no markup at all. <ClientOnly> keeps it out of the prerendered bundle. -->
    <ClientOnly>
      <DebugPanel />
    </ClientOnly>
  </div>
</template>

<script setup lang="ts">
import DebugPanel from '@/components/common/DebugPanel.vue'
import TopBar from '@/components/TopBar.vue'
import { useThreadStore } from '~/stores/thread'
import { useLiveFeed } from '~/stores/live'
import { usePaneWidths } from '~/composables/usePaneWidths'
import { CHANNEL, LIVE, NONE, closes, threadSection } from '~/utils/thread-pane.mjs'

const thread = useThreadStore()
const livePane = useLiveFeed('pane')
/* CLE-3429: the single source of truth for which thread section is on screen. */
const section = computed(() => threadSection({ paneTaskId: livePane.taskId, threadOpen: thread.open }))
const threadPaneOpen = computed(() => section.value !== NONE)

/* CLE-3429, the state half of 1..1: opening one section closes the other, so
   the section the reader opened LAST is the one they see. Without this a stale
   live pane would outrank a freshly opened channel thread and the click would
   look dead. `flush: 'sync'` so the losing store is cleared before the render
   that would otherwise show the wrong pane for one frame. Neither watcher can
   re-trigger the other: closing only ever writes the falsy side. */
watch(() => livePane.taskId, (id) => {
  if (id && closes(LIVE, { threadOpen: thread.open }) === CHANNEL) thread.close()
}, { flush: 'sync' })
watch(() => thread.open, (open) => {
  if (open && closes(CHANNEL, { paneTaskId: livePane.taskId }) === LIVE) livePane.close()
}, { flush: 'sync' })

const {
  displayed,
  sidebarBounds,
  threadBounds,
  showSidebarDivider,
  showThreadDivider,
  shellStyle,
  setSidebar,
  setThread,
  resetSidebar,
  resetThread,
} = usePaneWidths({ threadOpen: threadPaneOpen })
</script>

<style scoped>
.layout {
  max-width: 100%;
  min-width: 0;
  overflow-x: clip;
}
</style>
