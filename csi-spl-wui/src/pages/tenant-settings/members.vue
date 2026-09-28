<!-- Tenant settings -> Members (specs/046 §4.2): the users CRUD - the same
     list and edit pane as /users (<TenantUsers embedded />). members.invite. -->
<template>
  <div data-test="tenant-settings-members">
    <TenantUsers embedded />
  </div>
</template>

<script setup lang="ts">
import TenantUsers from '~/components/TenantUsers.vue'
</script>
