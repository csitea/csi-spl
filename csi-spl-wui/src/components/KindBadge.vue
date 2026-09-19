<template>
  <span class="kind" :class="'kind-' + kind">{{ te('feed.kind.' + kind) ? t('feed.kind.' + kind) : kind }}</span>
</template>

<script setup lang="ts">
defineProps<{ kind: string }>()
const { t, te } = useI18n({ useScope: 'global' })
</script>
