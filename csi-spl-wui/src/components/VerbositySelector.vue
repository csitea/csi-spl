<template>
  <select v-model="topic.verbosity" :aria-label="t('verbosity.label')">
    <option v-for="l in LEVELS" :key="l" :value="l">{{ t('verbosity.level.' + l) }}</option>
  </select>
</template>

<script setup lang="ts">
import { useTopicStore } from '~/stores/topic'
import { LEVELS } from '~/utils/verbosity.mjs'

const topic = useTopicStore()
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
select {
  background: var(--color-composer);
  color: var(--color-fg);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 4px 6px;
}
</style>
