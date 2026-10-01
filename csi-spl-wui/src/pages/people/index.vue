<!-- CLE-77794: the People landing (middle pane) before a person is picked. The
     list is the sidebar's People section; clicking a row opens /people/<id>. -->
<template>
  <div class="feed-col" data-test="people-index">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2>{{ t('sidebar.people') }}</h2>
      <SectionClose side="end" />
    </header>
    <div class="feed-body">
      <p class="muted people-empty" data-test="people-empty">{{ t('people.empty') }}</p>
    </div>
  </div>
</template>

<script setup lang="ts">
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.people-empty { padding: 16px; margin: 0; }
</style>
