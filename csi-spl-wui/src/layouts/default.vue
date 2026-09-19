<!-- App frame, shaped like the donor WUI's layouts/default.vue: one contained
     .layout box (no document x-scroll), the page content, and the gated
     diagnostics panel LAST so the most recent technical error is literally the
     bottom-most content of the page. The spool shell (sidebar, feed, thread
     panes) stays client-only: it reads sessionStorage/localStorage and opens
     the live socket. Vertical pane dividers are pointer+keyboard resizers. -->
<template>
  <div class="layout">
    <ClientOnly>
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
        <ThreadPane />
        <LiveThreadPane />
      </div>
      <!-- CLE-3402: the signed-in person's avatar + dropdown, top-right -->
      <div class="app-corner" data-test="app-corner">
        <!-- CLE-3403 (spec 021): the donor's header language switcher -->
        <LanguageSwitcher />
        <UserMenu />
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
import LanguageSwitcher from '@/components/LanguageSwitcher.vue'
import { useThreadStore } from '~/stores/thread'
import { useLiveFeed } from '~/stores/live'
import { usePaneWidths } from '~/composables/usePaneWidths'

const thread = useThreadStore()
const livePane = useLiveFeed('pane')
const threadPaneOpen = computed(() => thread.open || Boolean(livePane.taskId))
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
