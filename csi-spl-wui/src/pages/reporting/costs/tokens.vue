<!-- Spec 143 costs-redesign.md 3.4, slice S1 (SPL-3798): Reporting -> Costs -> Tokens, a shell (its
     title and a "coming" line, no data) until slice S8 builds it. Every member sees it (owner HUM-10,
     t1 1be0e370, msg 3f1c7128, answer 1 A: its own workspace's tokens, the operator admin all). -->
<template>
  <section class="costs-shell" data-test="costs-shell-tokens">
    <h3>{{ t('reporting.costs.page.tokens') }}</h3>
    <p class="muted" data-test="costs-shell-coming">{{ t('reporting.costs.coming') }}</p>
  </section>
</template>

<script setup lang="ts">
const { t } = useI18n({ useScope: 'global' })
</script>
