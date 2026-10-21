<!-- spec 143 5.2, task T051 (SPL-2791): the Issues tab, reserved. Its row in
     utils/reporting-tabs.mjs stays ready: false, so the bar never draws it;
     the lane that builds the report replaces this placeholder and flips it. -->
<template>
  <p class="reporting-soon muted" data-test="reporting-issues">{{ t('reporting.future.issues') }}</p>
</template>

<script setup lang="ts">
const { t } = useI18n({ useScope: 'global' })
</script>
