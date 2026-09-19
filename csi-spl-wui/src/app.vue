<template>
  <NuxtLayout>
    <NuxtPage />
  </NuxtLayout>
</template>

<script setup lang="ts">
// Site-wide head, shaped like the donor WUI's app.vue: the version stamp is a
// <meta name="version"> so a deployed page says which build it is without a
// fetch. Everything SEO-shaped is left out on purpose — the WUI is noindex.
const appVersion = String(useRuntimeConfig().public.appVersion || '')

useHead({
  meta: appVersion ? [{ name: 'version', content: appVersion }] : [],
})
</script>
