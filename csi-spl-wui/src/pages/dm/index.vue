<!-- SPL-2765 (owner, 2026-10-21): Direct messages picked on the rail from a
     channel, with no DM read yet. The channel's list and its reply panel
     close; the DM list on the left is this section's own pane and the way on,
     a row there opens /dm/<peer>. -->
<template>
  <div class="feed-col" data-test="dm-index">
    <header class="feed-header">
      <MobileBack />
      <h2>{{ t('sidebar.direct_messages') }}</h2>
    </header>
  </div>
</template>

<script setup lang="ts">
const { t } = useI18n({ useScope: 'global' })
</script>
