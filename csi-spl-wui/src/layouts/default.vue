<!-- App frame, shaped like the donor WUI's layouts/default.vue: one contained
     .layout box (no document x-scroll), the page content, and the gated
     diagnostics panel LAST so the most recent technical error is literally the
     bottom-most content of the page. The spool shell (sidebar, feed, thread
     panes) stays client-only: it reads sessionStorage/localStorage and opens
     the live socket. -->
<template>
  <div class="layout">
    <ClientOnly>
      <div class="spool-shell" style="max-width:100%;min-width:0">
        <ChannelSidebar />
        <main class="spool-main">
          <slot />
        </main>
        <ThreadPane />
        <LiveThreadPane />
      </div>
      <template #fallback>
        <div class="login"><p class="muted">Loading Spool…</p></div>
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
</script>

<style scoped>
.layout {
  max-width: 100%;
  min-width: 0;
  overflow-x: clip;
}
</style>
