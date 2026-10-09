<!-- Spec 112 WUI-3 (12.6): the roadmap's workspace filter. It lists only the
     workspaces the viewer may see (useRoadmapGoals): their memberships, or
     signed out the page host's public roadmap. The pick lives in the URL
     (?ws=<slug>, next to when and goal), so a link reproduces it. A ?ws= the
     viewer may not see is never listed and never read. Loaded by
     pages/roadmap.vue as its own chunk. -->
<template>
  <label v-if="options.length" class="roadmap-ws" data-test="roadmap-ws">
    <span class="roadmap-ws__label">{{ t('roadmap.goal_ws_label') }}</span>
    <select class="roadmap-ws__select" data-test="roadmap-ws-select" :value="ws" @change="onPick">
      <option v-for="o in options" :key="o.id" :value="o.id" data-test="roadmap-ws-option" :data-ws="o.id">{{ o.label }}</option>
    </select>
  </label>
</template>

<script setup lang="ts">
defineProps<{ options: { id: string, label: string }[], ws: string }>()
const emit = defineEmits<{ pick: [id: string] }>()

const { t } = useI18n({ useScope: 'global' })

function onPick(e: Event) {
  emit('pick', (e.target as HTMLSelectElement).value)
}
</script>

<style scoped>
.roadmap-ws {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  min-width: 0;
}
.roadmap-ws__label {
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--color-muted);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.roadmap-ws__select {
  max-width: 14rem;
  min-width: 0;
  padding: 0.2rem 0.4rem;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  background: var(--color-bg);
  color: var(--color-fg);
  font: inherit;
}
@media (max-width: 820px) {
  .roadmap-ws__select { min-height: var(--tap, 44px); }
}
</style>
