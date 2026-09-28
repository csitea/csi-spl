<!-- CLE-34969: the admin's Users page (specs/025 FR-012). The list and the
     edit pane are <TenantUsers />, which Tenant settings -> Members embeds
     too (SPL-1037, specs/046). -->
<template>
  <TenantUsers />
</template>

<script setup lang="ts">
import TenantUsers from '~/components/TenantUsers.vue'
</script>
