<!-- Spec 112 WUI-3 (6, 12.6): the roadmap's goal rows, one per goal of the
     shown workspace (its goal:<id>: events, utils/roadmap-goals), joined
     with the spec rows of roadmap.json. Columns: id, title (a link to the
     goal page), deadline with its countdown, approval, share-done and mean
     pct (6), and "its specs" (?goal=<id>, the spec rows of that goal). A goal
     read here is approved: the hub writes no event for a draft (12.3). At
     <= 820 px (spec 106) each row is a card. Loaded by pages/roadmap.vue as
     its own chunk; WUI-1's spec table stays RoadmapSpecTable.vue. -->
<template>
  <table class="roadmap-goals" data-test="roadmap-goal-table">
    <thead>
      <tr>
        <th scope="col">{{ t('goals.col_id') }}</th>
        <th scope="col">{{ t('goals.col_title') }}</th>
        <th scope="col">{{ t('goals.col_deadline') }}</th>
        <th scope="col">{{ t('goals.col_approval') }}</th>
        <th scope="col">{{ t('goals.col_share_done') }}</th>
        <th scope="col">{{ t('goals.col_mean_pct') }}</th>
        <th scope="col"><span class="roadmap-goals__sr">{{ t('roadmap.goal_specs') }}</span></th>
      </tr>
    </thead>
    <tbody>
      <tr
        v-for="r in view"
        :key="r.g.id"
        data-test="roadmap-goal-row"
        :data-goal="r.g.id"
        :class="{ 'roadmap-goals__row--focus': focus === r.g.id }"
      >
        <td :data-label="t('goals.col_id')"><code dir="ltr">{{ r.g.id }}</code></td>
        <td :data-label="t('goals.col_title')" class="roadmap-goals__title">
          <NuxtLink :to="goalHref(r.g.id)" data-test="roadmap-goal-link">{{ r.g.title || r.g.id }}</NuxtLink>
        </td>
        <td :data-label="t('goals.col_deadline')">
          <span v-if="r.g.deadline" class="roadmap-goals__deadline">
            <time dir="ltr" :datetime="r.g.deadline">{{ dayOf(r.g.deadline) }}</time>
            <span class="muted" data-test="roadmap-goal-countdown">{{ countdown(r.left) }}</span>
          </span>
        </td>
        <td :data-label="t('goals.col_approval')">
          <span class="roadmap-goals__state" data-test="roadmap-goal-approval">{{ t('goals.approved') }}</span>
        </td>
        <td :data-label="t('goals.col_share_done')" class="roadmap-goals__num" data-test="roadmap-goal-share">
          <template v-if="r.p.shareDone !== null"><span dir="ltr">{{ r.p.shareDone }}%</span> <span class="muted">{{ t('goals.share_done_value', { done: r.p.done, total: r.p.linked.length }) }}</span></template>
        </td>
        <td :data-label="t('goals.col_mean_pct')" class="roadmap-goals__num" data-test="roadmap-goal-mean">
          <span v-if="r.p.meanPct !== null" dir="ltr">{{ r.p.meanPct }}%</span>
        </td>
        <td :data-label="t('roadmap.goal_specs')">
          <NuxtLink :to="specsHref(r.g.id)" data-test="roadmap-goal-specs">{{ t('roadmap.goal_specs') }}</NuxtLink>
        </td>
      </tr>
    </tbody>
  </table>
</template>

<script setup lang="ts">
import { isoDate } from '~/utils/date-iso.mjs'
import { goalDaysLeft, goalProgress } from '~/utils/roadmap-goals.mjs'
import type { RoadmapGoal } from '~/composables/useRoadmapGoals'

const props = defineProps<{
  goals: RoadmapGoal[]
  specs: { id: string, state: string, pct: number | null }[]
  ws: string
  focus?: string
}>()

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const dayOf = (iso: string) => isoDate(iso) || iso.slice(0, 10)

const view = computed(() => {
  const today = isoDate(Date.now())
  return props.goals.map((g) => ({ g, p: goalProgress(g, props.specs), left: goalDaysLeft(g.deadline, today, dayOf) }))
})

function countdown(n: number | null): string {
  if (n === null) return ''
  if (n === 0) return t('goals.due_today')
  return n > 0 ? t('goals.days_left', { n }) : t('goals.days_over', { n: -n })
}

const goalHref = (id: string) => localePath({ path: `/goals/${id}`, query: props.ws ? { ws: props.ws } : {} })
const specsHref = (id: string) => localePath({ path: '/roadmap', query: { ...route.query, goal: id } })
</script>

<style scoped>
.roadmap-goals {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.875rem;
  margin-bottom: 1rem;
}
.roadmap-goals th,
.roadmap-goals td {
  text-align: start;
  padding: 0.4rem 0.6rem;
  border-bottom: 1px solid var(--color-border);
  overflow-wrap: anywhere;
  vertical-align: top;
}
.roadmap-goals th {
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--color-muted);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.roadmap-goals code {
  font-family: var(--font-mono);
  font-size: 0.8125rem;
}
.roadmap-goals__sr {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip-path: inset(50%);
  white-space: nowrap;
}
.roadmap-goals__row--focus { background: var(--color-selected); }
.roadmap-goals__deadline {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 0 0.4rem;
}
.roadmap-goals__num { white-space: nowrap; }
.roadmap-goals__state {
  display: inline-block;
  padding: 0 0.4rem;
  border-radius: var(--radius-pill);
  border: 1px solid currentColor;
  color: var(--color-ok);
  font-size: 0.75rem;
  white-space: nowrap;
  justify-self: start;
}
@media (max-width: 820px) {
  .roadmap-goals,
  .roadmap-goals tbody,
  .roadmap-goals tr,
  .roadmap-goals td { display: block; }
  .roadmap-goals thead {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }
  .roadmap-goals tr {
    padding: 0.5rem 0.75rem;
    margin-bottom: 0.5rem;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
  }
  .roadmap-goals td {
    display: grid;
    grid-template-columns: 6.5rem minmax(0, 1fr);
    gap: 0.5rem;
    padding: 0.2rem 0;
    border-bottom: 0;
    white-space: normal;
  }
  .roadmap-goals td::before {
    content: attr(data-label);
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--color-muted);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  .roadmap-goals td > a { min-height: var(--tap, 44px); display: inline-flex; align-items: center; }
}
</style>
