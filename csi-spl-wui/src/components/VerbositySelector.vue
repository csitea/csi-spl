<template>
  <select v-model="thread.verbosity" :aria-label="t('verbosity.label')">
    <option v-for="l in LEVELS" :key="l" :value="l">{{ t('verbosity.level.' + l) }}</option>
  </select>
</template>

<script setup lang="ts">
import { useThreadStore } from '~/stores/thread'
import { LEVELS } from '~/utils/verbosity.mjs'

const thread = useThreadStore()
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
select {
  background: var(--color-composer);
  color: var(--color-fg);
  border: 1px solid var(--color-border);
  border-radius: 6px;
  padding: 4px 6px;
}
</style>
