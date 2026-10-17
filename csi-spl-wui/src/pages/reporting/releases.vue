<!-- spec 143 1.3 (SPL-2351): where /reporting lands. The Releases report
     itself (spec 143 2, tasks T022-T024) replaces this placeholder. -->
<template>
  <p class="reporting-soon muted" data-test="reporting-releases">{{ t('reporting.releases.soon') }}</p>
</template>

<script setup lang="ts">
const { t } = useI18n({ useScope: 'global' })
</script>
