<!-- CLE-77794: the Agents landing (middle pane) before an agent is picked. The
     list is the sidebar's Agents section; clicking a row opens /agents/<id>. -->
<template>
  <div class="feed-col" data-test="agents-index">
    <header class="feed-header">
      <MobileBack />
      <h2>{{ t('sidebar.agents') }}</h2>
    </header>
    <div class="feed-body">
      <p class="muted agents-empty" data-test="agents-empty">{{ t('agents.empty') }}</p>
    </div>
  </div>
</template>

<script setup lang="ts">
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.agents-empty { padding: 16px; margin: 0; }
</style>
