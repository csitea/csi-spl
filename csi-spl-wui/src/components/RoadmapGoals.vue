<!-- Spec 112 WUI-3 (6, 12.6): the roadmap's goal part, above WUI-1's spec
     rows: the workspace filter, then the goal rows of that workspace, or why
     there are none (signed out on an internal roadmap; a ?ws= the viewer may
     not see; a membership that needs the tenant switch first). State comes
     from useRoadmapGoals in pages/roadmap.vue, which also filters the spec
     rows by the goals (5.3 (a), ?goal=). Loaded as its own chunk. -->
<template>
  <section class="roadmap-goal-part" data-test="roadmap-goals" :data-state="state" :data-ws="ws">
    <div class="roadmap-goal-bar">
      <h3 class="roadmap-goal-heading">{{ t('roadmap.goal_heading') }}</h3>
      <RoadmapWorkspaceFilter :options="workspaces" :ws="ws" @pick="(id: string) => emit('pick', id)" />
      <NuxtLink v-if="focus" :to="allHref" class="roadmap-goal-clear" data-test="roadmap-goal-clear">{{ t('roadmap.goal_filter_clear') }}</NuxtLink>
    </div>
    <p v-if="blocked" class="muted roadmap-goal-note" role="status" data-test="roadmap-goal-blocked">{{ t('roadmap.goal_blocked') }}</p>
    <p v-if="otherWs" class="muted roadmap-goal-note" data-test="roadmap-goal-switch-note">
      {{ t('roadmap.goal_switch_note', { ws: otherWs }) }}
      <button type="button" class="btn ghost" data-test="roadmap-goal-switch" :disabled="switching" @click="emit('switch')">{{ t('roadmap.goal_switch', { ws: otherWs }) }}</button>
    </p>
    <p v-else-if="state === 'loading'" class="muted roadmap-goal-note" data-test="roadmap-goal-loading">{{ t('common.loading') }}</p>
    <p v-else-if="state === 'error'" class="roadmap-goal-note roadmap-goal-error" role="alert" data-test="roadmap-goal-error">{{ t('roadmap.goal_error') }}</p>
    <p v-else-if="!goals.length" class="muted roadmap-goal-note" data-test="roadmap-goal-empty">{{ t(ws ? 'roadmap.goal_empty' : 'roadmap.goal_ws_none') }}</p>
    <RoadmapGoalTable v-else :goals="goals" :specs="specs" :ws="ws" :focus="focus" />
  </section>
</template>

<script setup lang="ts">
import RoadmapGoalTable from '~/components/RoadmapGoalTable.vue'
import RoadmapWorkspaceFilter from '~/components/RoadmapWorkspaceFilter.vue'
import type { RoadmapGoal } from '~/composables/useRoadmapGoals'

defineProps<{
  workspaces: { id: string, label: string }[]
  ws: string
  blocked: string
  otherWs: string
  switching: boolean
  state: 'loading' | 'ready' | 'error'
  goals: RoadmapGoal[]
  specs: { id: string, state: string, pct: number | null }[]
  focus: string
}>()
const emit = defineEmits<{ pick: [id: string], switch: [] }>()

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const allHref = computed(() => localePath({ path: '/roadmap', query: { ...route.query, goal: undefined } }))
</script>

<style scoped>
.roadmap-goal-part { margin-bottom: 1rem; min-width: 0; }
.roadmap-goal-bar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem 1rem;
  margin-bottom: 0.5rem;
}
.roadmap-goal-heading {
  margin: 0;
  font-size: 0.875rem;
  font-weight: 600;
}
.roadmap-goal-note { margin: 0 0 0.5rem; overflow-wrap: anywhere; }
.roadmap-goal-error { color: var(--color-danger); }
@media (max-width: 820px) {
  .roadmap-goal-clear { min-height: var(--tap, 44px); display: inline-flex; align-items: center; }
}
</style>
