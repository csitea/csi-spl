<!-- SPL-18: the Issues tab's side panel - the
     level-1 rows (epics and features), like Linear's projects: a kind dot,
     done / open count and a progress bar; a click filters the list to one
     (/issues?epic=SPL-17). The Issues page fills the shared state from the
     hub summary. Its own component, loaded only on the Issues tab, so the
     initial script does not carry it (perf-budget ci_initial_gzip_kb). -->
<template>
  <div class="issue-epics">
    <h2 v-if="issueEpics.length" data-testid="sidebar-epics-h">{{ t('sidebar.epics') }}</h2>
    <!-- SPL-1146: the rows scroll inside the panel, above the sidebar footer;
         without a scroller they ran on under the footer bar -->
    <div class="sidebar-scroll" data-testid="sidebar-epics-scroll">
    <NuxtLink
      v-for="e in issueEpics"
      :key="e.key"
      class="nav-item epic-row"
      :class="{ active: epicQuery === e.key, 'epic-row--closed': e.status === 'done' || e.status === 'diss' }"
      data-testid="sidebar-epic"
      :data-key="e.key"
      :title="`${e.key} ${e.title}`"
      :to="localePath({ path: '/issues', query: { epic: e.key } })"
      @contextmenu="onEpicContext(e, $event)"
      @pointerdown="onEpicPointerDown(e, $event)"
      @pointermove="epicPress.move($event)"
      @pointerup="epicPress.up()"
      @pointercancel="epicPress.cancel()"
      @click="onEpicClick($event)"
      @dblclick="onEpicEdit(e, $event)"
    >
      <span class="epic-row__title"><i class="epic-row__kind" :data-kind="e.kind || 'epic'" :title="t('issues.kind_' + (e.kind || 'epic'))" />{{ e.title }}</span>
      <span class="epic-row__count" data-testid="sidebar-epic-count">{{ e.done }}/{{ e.total - e.canceled }}</span>
      <span class="epic-row__bar" aria-hidden="true"><span :style="{ width: epicPct(e) + '%' }" /></span>
    </NuxtLink>
    </div>
  </div>
</template>

<script setup lang="ts">
import { createLongPress } from '~/utils/touch-ui.mjs'
import { useIssueMenu, type IssueMenuTarget } from '~/composables/useIssueMenu'

type EpicRow = { key: string, kind?: string, title: string, status: string, total: number, done: number, canceled: number }

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const issueEpics = useState<EpicRow[]>('issue-epics', () => [])

/* SPL-1226: right-click / long-press an epic or feature to archive or delete it
   (with its whole subtree). The Issues page renders the shared menu; this panel
   only opens it. */
const { openAt: openCtxMenu, requestEdit } = useIssueMenu()
function epicTarget(e: EpicRow): IssueMenuTarget {
  return { key: e.key, kind: e.kind || 'epic', level: 1, title: e.title, top: true }
}
/* CLE-77816: a double-click opens the epic / feature in the issue dialog.
   The first click already navigated to its list (?epic=); the page opens the
   shared dialog on top, so you land on the epic and can edit it at once. */
function onEpicEdit(e: EpicRow, ev: MouseEvent) {
  ev.preventDefault()
  ev.stopPropagation()
  requestEdit(epicTarget(e))
}
let pressTarget: IssueMenuTarget | null = null
const epicPress = createLongPress({ onPress: (x, y) => { if (pressTarget) openCtxMenu(pressTarget, x, y) } })
function onEpicContext(e: EpicRow, ev: MouseEvent) {
  ev.preventDefault()
  ev.stopPropagation()
  openCtxMenu(epicTarget(e), ev.clientX, ev.clientY)
}
function onEpicPointerDown(e: EpicRow, ev: PointerEvent) { pressTarget = epicTarget(e); epicPress.down(ev) }
/* the click a long-press lifts must not also navigate to the epic's list */
function onEpicClick(ev: MouseEvent) { if (epicPress.takeClick()) { ev.preventDefault(); ev.stopPropagation() } }
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
.issue-epics { flex: 1 1 auto; min-height: 0; display: flex; flex-direction: column; }
.epic-row { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 2px 8px; align-items: center; }
.epic-row__title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.epic-row__count { font-size: 0.75rem; opacity: 0.75; font-variant-numeric: tabular-nums; }
.epic-row__bar { grid-column: 1 / -1; height: 3px; border-radius: var(--radius-pill); background: color-mix(in srgb, currentColor 18%, transparent); overflow: hidden; }
.epic-row__bar > span { display: block; height: 100%; background: var(--color-accent); }
.epic-row--closed { opacity: 0.6; }
.epic-row__kind { display: inline-block; width: 0.5rem; height: 0.5rem; margin-inline-end: 6px; border-radius: var(--radius-pill); background: var(--color-kind-epic); vertical-align: middle; }
.epic-row__kind[data-kind="feature"] { background: var(--color-kind-feature); }
/* SPL-992 (epic SPL-988): on a phone this panel is level 1, full width - a
   row is a 44 px touch target, and a tap opens the epic's list (level 2) */
@media (max-width: 820px) {
  .epic-row { min-height: var(--tap, 44px); align-content: center; }
}
</style>
