<!-- Spec 112 WUI-3 (6, 4.4, 12.6): the goal page, /goals/<id>?ws=<slug>.
     One goal of the shown workspace (useRoadmapGoals: the viewer's
     memberships, or signed out a public roadmap of the page host), from its
     goal:<id>: events joined with the spec rows of /roadmap.json (fetched,
     never imported, as on the roadmap). It shows the deadline countdown, the
     approval state (an event exists only for an approved goal, 12.3), the
     done-lines, share-done and mean pct (6), the linked specs with their
     pct, the milestones, and links to the calendar events
     (/calendar?d=<day>&event=<id>, signed in) and to strategy.md when the
     event carries it. A goal the viewer may not see reads "not found". -->
<template>
  <div class="feed-col goal-page" data-test="goal-page" :data-goal="id">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 data-test="goal-heading">{{ g ? (g.title || g.id) : t('goals.page_title', { id }) }}</h2>
      <span class="goal-spacer" />
      <SectionClose side="end" />
    </header>
    <div class="feed-body goal-body">
      <p class="goal-back"><NuxtLink :to="roadmapHref" data-test="goal-roadmap-link">{{ t('goals.back') }}</NuxtLink></p>
      <p v-if="goalsOf.state.value === 'loading'" class="muted" data-test="goal-loading">{{ t('common.loading') }}</p>
      <p v-else-if="goalsOf.state.value === 'error'" class="goal-error" role="alert" data-test="goal-error">{{ t('roadmap.goal_error') }}</p>
      <p v-else-if="!g" class="muted" data-test="goal-not-found">{{ t('goals.not_found') }}</p>
      <template v-else>
        <dl class="goal-facts">
          <div>
            <dt>{{ t('goals.col_id') }}</dt>
            <dd><code dir="ltr">{{ g.id }}</code></dd>
          </div>
          <div>
            <dt>{{ t('goals.col_deadline') }}</dt>
            <dd>
              <template v-if="g.deadline">
                <time dir="ltr" :datetime="g.deadline">{{ dayOf(g.deadline) }}</time>
                <span class="muted" data-test="goal-countdown">{{ countdown }}</span>
                <NuxtLink v-if="calHref(g.deadline, g.eventId)" :to="calHref(g.deadline, g.eventId)" data-test="goal-calendar-link">{{ t('goals.calendar_link') }}</NuxtLink>
              </template>
            </dd>
          </div>
          <div>
            <dt>{{ t('goals.col_approval') }}</dt>
            <dd><span class="goal-state" data-test="goal-approval">{{ t('goals.approved') }}</span></dd>
          </div>
          <div>
            <dt>{{ t('goals.col_share_done') }}</dt>
            <dd data-test="goal-share">
              <template v-if="progress.shareDone !== null"><span dir="ltr">{{ progress.shareDone }}%</span> <span class="muted">{{ t('goals.share_done_value', { done: progress.done, total: progress.linked.length }) }}</span></template>
            </dd>
          </div>
          <div>
            <dt>{{ t('goals.col_mean_pct') }}</dt>
            <dd data-test="goal-mean"><span v-if="progress.meanPct !== null" dir="ltr">{{ progress.meanPct }}%</span></dd>
          </div>
          <div v-if="g.strategyUrl">
            <dt>{{ t('goals.strategy_link') }}</dt>
            <dd><a :href="g.strategyUrl" target="_blank" rel="noopener" data-test="goal-strategy-link">strategy.md</a></dd>
          </div>
        </dl>

        <h3 class="goal-h">{{ t('goals.done_lines') }}</h3>
        <ul v-if="g.doneLines.length" class="goal-list" data-test="goal-done-lines">
          <li v-for="(l, i) in g.doneLines" :key="i" data-test="goal-done-line">{{ l }}</li>
        </ul>
        <p v-else class="muted">{{ t('goals.none') }}</p>

        <h3 class="goal-h">{{ t('goals.specs') }}</h3>
        <ul v-if="g.specs.length" class="goal-list" data-test="goal-specs">
          <li v-for="s in specRows" :key="s.id" data-test="goal-spec" :data-spec="s.id">
            <NuxtLink :to="specHref(s.id)"><code dir="ltr">{{ s.id }}</code></NuxtLink>
            <span v-if="s.row" class="goal-spec__title">{{ s.row.title }}</span>
            <span v-if="s.row && typeof s.row.pct === 'number'" class="muted" dir="ltr" data-test="goal-spec-pct">{{ s.row.pct }}%</span>
          </li>
        </ul>
        <p v-else class="muted">{{ t('goals.none') }}</p>

        <template v-if="g.milestones.length">
          <h3 class="goal-h">{{ t('goals.milestones') }}</h3>
          <ul class="goal-list" data-test="goal-milestones">
            <li v-for="m in g.milestones" :key="m.key" data-test="goal-milestone" :data-key="m.key">
              <time dir="ltr" :datetime="m.at">{{ dayOf(m.at) }}</time>
              <span>{{ m.title || m.key }}</span>
              <NuxtLink v-if="calHref(m.at, m.eventId)" :to="calHref(m.at, m.eventId)">{{ t('goals.calendar_link') }}</NuxtLink>
            </li>
          </ul>
        </template>
      </template>
    </div>
  </div>
</template>

<script setup lang="ts">
import { isoDate } from '~/utils/date-iso.mjs'
import { roadmapSpecs } from '~/utils/roadmap-rows.mjs'
import { goalCalendarHref, goalDaysLeft, goalProgress, roadmapGoalId } from '~/utils/roadmap-goals.mjs'

interface SpecRow { id: string, title: string, state: string, pct: number | null }

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const goalsOf = useRoadmapGoals()

const id = computed(() => roadmapGoalId(route.params.id) || String(route.params.id || ''))
const g = computed(() => goalsOf.goals.value.find((x) => x.id === id.value) || null)
const specs = ref<SpecRow[]>([])
const dayOf = (iso: string) => isoDate(iso) || iso.slice(0, 10)

const progress = computed(() => goalProgress(g.value || { specs: [] }, specs.value))
const specRows = computed(() => (g.value ? g.value.specs : []).map((s) => ({ id: s, row: specs.value.find((r) => r.id.slice(0, 3) === s) || null })))
const countdown = computed(() => {
  const n = g.value ? goalDaysLeft(g.value.deadline, isoDate(Date.now()), dayOf) : null
  if (n === null) return ''
  if (n === 0) return t('goals.due_today')
  return n > 0 ? t('goals.days_left', { n }) : t('goals.days_over', { n: -n })
})

const wsQuery = computed(() => (goalsOf.ws.value ? { ws: goalsOf.ws.value } : {}))
const roadmapHref = computed(() => localePath({ path: '/roadmap', query: wsQuery.value }))
const specHref = (s: string) => localePath({ path: '/roadmap', query: { ...wsQuery.value, goal: id.value }, hash: `#spec-${s}` })
const calHref = (at: string, eventId: string) => {
  const href = goalCalendarHref(at, eventId, dayOf)
  return href ? localePath(href) : ''
}

/* fetched, never imported (spec 112 9); a failure leaves the pct cells empty */
onMounted(async () => {
  try {
    const res = await fetch('/roadmap.json', { cache: 'no-cache' })
    if (res.ok) specs.value = roadmapSpecs(await res.json()) as SpecRow[]
  } catch { /* the goal still shows */ }
})

useHead(() => ({ title: g.value ? (g.value.title || g.value.id) : t('goals.page_title', { id: id.value }) }))
</script>

<style scoped>
.goal-spacer { flex: 1 1 auto; }
.goal-body { min-width: 0; overflow-wrap: anywhere; }
.goal-back { margin: 0 0 0.75rem; }
.goal-error { color: var(--color-danger); }
.goal-facts {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(12rem, 1fr));
  gap: 0.75rem 1.5rem;
  margin: 0 0 1rem;
}
.goal-facts dt {
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--color-muted);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.goal-facts dd {
  margin: 0.2rem 0 0;
  display: flex;
  flex-wrap: wrap;
  gap: 0.25rem 0.5rem;
  align-items: baseline;
}
.goal-state {
  padding: 0 0.4rem;
  border-radius: var(--radius-pill);
  border: 1px solid currentColor;
  color: var(--color-ok);
  font-size: 0.75rem;
}
.goal-h { margin: 1rem 0 0.4rem; font-size: 0.875rem; font-weight: 600; }
.goal-list { margin: 0; padding-inline-start: 1.25rem; }
.goal-list li { margin: 0.2rem 0; display: list-item; }
.goal-list li > * + * { margin-inline-start: 0.5rem; }
.goal-list code { font-family: var(--font-mono); font-size: 0.8125rem; }
@media (max-width: 820px) {
  .goal-facts { grid-template-columns: minmax(0, 1fr); }
  .goal-back a { min-height: var(--tap, 44px); display: inline-flex; align-items: center; }
}
</style>
