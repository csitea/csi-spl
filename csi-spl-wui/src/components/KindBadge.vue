<template>
  <span class="kind" :class="'kind-' + kind">{{ kind }}</span>
</template>

<script setup lang="ts">
defineProps<{ kind: string }>()
</script>
