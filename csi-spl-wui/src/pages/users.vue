<!-- /users: owner 2026-09-28 (topic bea3a4e6), "the users CRUD will be
     accessible only from the app settings". The list and edit pane live in
     Settings -> Members (<TenantUsers embedded />, SPL-1037); an old link or
     bookmark lands there, with its query and hash. -->
<template>
  <p class="muted">{{ t('common.loading') }}</p>
</template>

<script setup lang="ts">
const localePath = useLocalePath()
const route = useRoute()
const { t } = useI18n({ useScope: 'global' })
if (import.meta.client) {
  void navigateTo({ path: localePath('/tenant-settings/members'), query: route.query, hash: route.hash }, { replace: true })
}
</script>
