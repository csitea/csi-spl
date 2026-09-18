<template>
  <select v-model="thread.verbosity" aria-label="Thread verbosity">
    <option value="minimal">minimal</option>
    <option value="normal">normal</option>
    <option value="verbose">verbose</option>
  </select>
</template>

<script setup lang="ts">
import { useThreadStore } from '~/stores/thread'

const thread = useThreadStore()
</script>

<style scoped>
select {
  background: var(--sp-composer);
  color: var(--sp-text);
  border: 1px solid var(--sp-border);
  border-radius: 6px;
  padding: 4px 6px;
}
</style>
