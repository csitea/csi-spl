<!-- SPL-5312 (spec 143 costs-redesign.md 3.9; owner HUM-10, t1 41a74806):
     Reporting -> Costs -> Cloud, one of the four labels; its own route and
     chunk. Everything is components/reporting/costs/CostsLabel.vue. -->
<template>
  <CostsLabel section="cloud" />
</template>

<script setup lang="ts">
import CostsLabel from '~/components/reporting/costs/CostsLabel.vue'
</script>
