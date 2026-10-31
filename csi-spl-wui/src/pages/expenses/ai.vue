<!-- Spec 143 costs-redesign.md 3.8 (SPL-4382): Expenses -> AI costs, the paid
     subscriptions and top-ups of the fleet's AI vendors (spec 140 3.8,
     SPL-2567), entered here and moved from Monitoring -> Tokens: the Paid
     card with its form, its list and the effective price per token. Its own
     chunk; the wrapper keeps the async component off a bare v-if. The card
     draws nothing on the hub's 403. -->
<template>
  <section class="expenses-ai" data-test="expenses-ai">
    <div class="tk-lazy"><PaidItemsCard /></div>
  </section>
</template>

<script setup lang="ts">
const PaidItemsCard = defineAsyncComponent(() => import('~/components/monitoring/token-burn/PaidItemsCard.vue'))
</script>

<style scoped>
.tk-lazy { display: contents; }
</style>
