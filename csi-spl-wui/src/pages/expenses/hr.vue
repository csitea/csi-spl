<!-- Spec 143 costs-redesign.md 3.8 (SPL-4382; owner HUM-10, t1 4f48f878, msg
     b0ccc0aa: "different types for the INSERTION Of at least the following
     type of costs - AI costs , cloud infra cost , HR costs"): Expenses ->
     HR costs. Its entry needs storage the hub does not hold yet (the
     SPL-4382 split, lane B: the cost entries table, its hub routes and this
     tab's form and list); until then the tab says so, never a number. -->
<template>
  <section class="expenses-type" data-test="expenses-hr">
    <h3>{{ t('expenses.tab.hr') }}</h3>
    <p class="muted" data-test="expenses-coming">{{ t('expenses.coming') }}</p>
  </section>
</template>

<script setup lang="ts">
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.expenses-type { display: flex; flex-direction: column; gap: 8px; }
.expenses-type h3 { margin: 0; font-size: 1rem; }
</style>
