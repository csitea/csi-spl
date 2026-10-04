<!-- Tenant settings -> Fleet load (rdb 0118). The card itself is
     components/FleetLoadCard.vue. The route exists for every workspace;
     the card and the nav entry render only after GET /v1/operator/fleet-load
     succeeds. -->
<template>
  <FleetLoadCard />
</template>

<script setup lang="ts">
import FleetLoadCard from '~/components/FleetLoadCard.vue'
</script>
