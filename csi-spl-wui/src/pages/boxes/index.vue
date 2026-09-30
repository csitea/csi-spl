<!-- CLE-77799: the Boxes landing (middle pane) before a box is picked. The list
     is the sidebar's Boxes section; clicking a row opens /boxes/<box_id>. -->
<template>
  <div class="feed-col" data-test="boxes-index">
    <header class="feed-header">
      <MobileBack />
      <h2>{{ t('sidebar.boxes') }}</h2>
    </header>
    <div class="feed-body">
      <p class="muted boxes-empty" data-test="boxes-empty">{{ t('boxes.empty') }}</p>
    </div>
  </div>
</template>

<script setup lang="ts">
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.boxes-empty { padding: 16px; margin: 0; }
</style>
