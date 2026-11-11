<!-- Tenant settings -> Cost allocation (SPL-5291, spec 143
     costs-allocation.md). The card itself is components/CostAllocationCard.vue.
     The route exists for every workspace; the nav entry shows only after
     tenant-settings.vue's probe found a door (the operator's admin, or a
     customer admin holding a share to split). -->
<template>
  <CostAllocationCard />
</template>

<script setup lang="ts">
import CostAllocationCard from '~/components/CostAllocationCard.vue'
</script>
