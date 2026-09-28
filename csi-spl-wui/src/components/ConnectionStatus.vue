<!-- Owner 2026-09-27 (topic 86a570ea): on phones the hub connection sits in
     the avatar sheet next to the bell and the note - the sidebar footer's dot
     (ok / warn / down) and its words. Async in UserMenu: it reads the live
     socket state, and the live store stays out of the first download. It
     opens no socket. -->
<template>
  <span class="conn" data-test="user-menu-connection-state">
    <span class="conn__dot" :class="health" data-test="user-menu-connection-dot" aria-hidden="true" />
    <span data-test="user-menu-connection-label">{{ t('sidebar.health_title', { state: t('sidebar.health.' + health) }) }}</span>
  </span>
</template>

<script setup lang="ts">
import { useLive } from '~/composables/useLive'
import { connectionHealth } from '~/utils/channel-feed.mjs'

const { t } = useI18n({ useScope: 'global' })
const liveState = useLive().state
const health = computed(() => connectionHealth(liveState.value))
</script>

<style scoped>
.conn { display: inline-flex; align-items: center; gap: 8px; }
.conn__dot { width: 10px; height: 10px; border-radius: 50%; flex: none; background: var(--color-danger); }
.conn__dot.ok { background: var(--color-ok); }
.conn__dot.warn { background: var(--color-muted); }
</style>
