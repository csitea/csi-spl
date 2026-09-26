<!-- SPL-18: the Issues tab's left-most panel below "All issues" - the
     level-1 rows (epics and features), like Linear's projects: a kind dot,
     done / open count and a progress bar; a click filters the list to one
     (/issues?epic=SPL-17). The Issues page fills the shared state from the
     hub summary. Its own component, loaded only on the Issues tab, so the
     initial script does not carry it (perf-budget ci_initial_gzip_kb). -->
<template>
  <div class="issue-epics">
    <h2 v-if="issueEpics.length" data-testid="sidebar-epics-h">{{ t('sidebar.epics') }}</h2>
    <NuxtLink
      v-for="e in issueEpics"
      :key="e.key"
      class="nav-item epic-row"
      :class="{ active: epicQuery === e.key, 'epic-row--closed': e.status === 'done' || e.status === 'canceled' }"
      data-testid="sidebar-epic"
      :data-key="e.key"
      :title="`${e.key} ${e.title}`"
      :to="localePath({ path: '/issues', query: { epic: e.key } })"
    >
      <span class="epic-row__title"><i class="epic-row__kind" :data-kind="e.kind || 'epic'" :title="t('issues.kind_' + (e.kind || 'epic'))" />{{ e.title }}</span>
      <span class="epic-row__count" data-testid="sidebar-epic-count">{{ e.done }}/{{ e.total - e.canceled }}</span>
      <span class="epic-row__bar" aria-hidden="true"><span :style="{ width: epicPct(e) + '%' }" /></span>
    </NuxtLink>
  </div>
</template>

<script setup lang="ts">
type EpicRow = { key: string, kind?: string, title: string, status: string, total: number, done: number, canceled: number }

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const issueEpics = useState<EpicRow[]>('issue-epics', () => [])
const epicQuery = computed(() => {
  const q = route.query.epic
  const raw = Array.isArray(q) ? q[0] : q
  return typeof raw === 'string' ? raw.trim().toUpperCase() : ''
})
function epicPct(e: EpicRow) {
  const open = e.total - e.canceled
  return open > 0 ? Math.round((e.done * 100) / open) : 0
}
</script>

<style scoped>
.epic-row { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 2px 8px; align-items: center; }
.epic-row__title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.epic-row__count { font-size: 0.75rem; opacity: 0.75; font-variant-numeric: tabular-nums; }
.epic-row__bar { grid-column: 1 / -1; height: 3px; border-radius: var(--radius-pill); background: color-mix(in srgb, currentColor 18%, transparent); overflow: hidden; }
.epic-row__bar > span { display: block; height: 100%; background: var(--color-accent); }
.epic-row--closed { opacity: 0.6; }
.epic-row__kind { display: inline-block; width: 0.5rem; height: 0.5rem; margin-inline-end: 6px; border-radius: var(--radius-pill); background: #8b5cf6; vertical-align: middle; }
.epic-row__kind[data-kind="feature"] { background: #14b8a6; }
</style>
