<!-- CLE-77853: the old Settings addresses (/settings, /settings/<section>,
     /fi/settings/keys). Settings is a modal over the current view now
     (components/SettingsDialog.vue); middleware/settings-modal.global.ts
     sends this address to the last view (or the lobby) with ?settings=<id>
     before this page ever renders. This file only keeps the route matched. -->
<template>
  <p class="muted">{{ t('common.loading') }}</p>
</template>

<script setup lang="ts">
const { t } = useI18n({ useScope: 'global' })
</script>
