<!-- Spec 170 row B2 (owner HUM-10, csitea topic dfe850d9; SPL-5595): the
     desktop Calendar's To-do view, `?k=todo`. Tasks only (open issues, not
     epics or features, with a deadline; utils/day-tasks.mjs), never events,
     official days or notes (owner poll 30b44091 = B). The range, Today,
     previous / next and the title are the event views' (CalendarViewTabs);
     Month lists the month's own days (calTodoRange). Each range is a list
     grouped by day; when it holds today, the overdue tasks come first,
     marked (owner Q3 = A). A row opens the issue in Issues; Back returns
     here, the URL keeps k, v and d. Read-only (panel default). "Mine" by
     default with a switch to everyone's (owner Q2 = A), kept for this tab,
     not saved. It re-reads on an issue frame, a reconnect, a deadline saved
     in this tab and window focus. Its own lazy chunk, loaded by
     CalendarMainView only when the kind is todo. -->
<template>
  <section class="cal-todo" data-test="calendar-todo" :data-state="state" :data-mine="mine ? 'true' : 'false'" :aria-label="t('calendar_todo.title')">
    <header class="cal-todo__head">
      <h3 class="cal-todo__title">{{ t('calendar_todo.title') }}</h3>
      <div class="cal-todo__chips" role="group" :aria-label="t('calendar_todo.whose')">
        <button type="button" class="cal-todo__chip" data-test="calendar-todo-mine" :aria-pressed="mine ? 'true' : 'false'" @click="mine = true">{{ t('calendar_todo.mine') }}</button>
        <button type="button" class="cal-todo__chip" data-test="calendar-todo-all" :aria-pressed="mine ? 'false' : 'true'" @click="mine = false">{{ t('calendar_todo.all') }}</button>
      </div>
    </header>
    <p v-if="state === 'failed'" class="muted" role="alert" data-test="calendar-todo-failed">{{ t('calendar_todo.load_failed') }}</p>
    <p v-else-if="state === 'ready' && !sections.length" class="muted cal-todo__empty" data-test="calendar-todo-empty">{{ t('calendar_todo.empty_range') }}</p>
    <section
      v-for="s in sections"
      :key="s.day || 'overdue'"
      class="cal-todo__day"
      :class="{ 'cal-todo__day--overdue': s.overdue, 'cal-todo__day--today': s.day === today }"
      :data-test="s.overdue ? 'calendar-todo-overdue' : 'calendar-todo-day'"
      :data-day="s.day || undefined"
    >
      <h4 class="cal-todo__dayhead">
        <template v-if="s.overdue">{{ t('calendar_todo.overdue') }}</template>
        <template v-else>{{ t('calendar.weekdays.d' + calWeekday(s.day)) }} <span dir="ltr">{{ s.day }}</span></template>
        <span v-if="s.day === today" class="cal-todo__tag">{{ t('calendar.today') }}</span>
      </h4>
      <p v-if="!s.tasks.length" class="muted cal-todo__none" data-test="calendar-todo-empty-day">{{ t('calendar_todo.empty_day') }}</p>
      <ul v-else class="cal-todo__list">
        <li v-for="i in s.tasks" :key="i.key" class="cal-todo__row" data-test="calendar-todo-row" :data-key="i.key" :data-overdue="s.overdue ? 'true' : undefined">
          <NuxtLink :to="localePath(issuePageHref(i.key))" class="cal-todo__link" data-test="calendar-todo-open">
            <span class="cal-todo__time" dir="ltr">{{ s.overdue ? isoDateTime(i.deadline) : isoClock(i.deadline) }}</span>
            <span class="cal-todo__key" dir="ltr">{{ i.key }}</span>
            <span class="cal-todo__name">{{ i.title }}</span>
            <span class="cal-todo__meta" dir="ltr" :title="t('issues.status_hint.' + i.status)">{{ statusLabel(i.status) }}</span>
            <span class="cal-todo__meta" dir="ltr">{{ t('calendar_todo.priority', { n: i.priority }) }}</span>
            <span v-if="!mine" class="cal-todo__meta" data-test="calendar-todo-assignee">{{ i.assignee || t('calendar_todo.unassigned') }}</span>
          </NuxtLink>
        </li>
      </ul>
    </section>
  </section>
</template>

<script setup lang="ts">
import { calWeekday } from '~/utils/calendar-year.mjs'
import { calTodoRange } from '~/utils/calendar-desktop-view.mjs'
import { taskFilters, todoSections } from '~/utils/day-tasks.mjs'
import { isoClock, isoDateTime } from '~/utils/date-iso.mjs'
import { issuePageHref } from '~/utils/issue-calendar-link.mjs'
import { statusLabel } from '~/utils/issues-view.mjs'
import { CALENDAR_CHANGED_EVENT } from '~/utils/calendar-reminders.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'

type Task = { key: string, title: string, status: string, priority: number, deadline: string, assignee: string }

const props = defineProps<{ focus: string, today: string, view: string }>()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const api = useSpoolApi()
const live = useLive()

/* owner Q2 = A: mine, with a switch; kept for this tab, so Back keeps it */
const mine = useState('calendar-todo-mine', () => true)
const range = computed(() => calTodoRange(props.view, props.focus))
const rows = shallowRef<Task[]>([])
const late = shallowRef<Task[]>([])
const state = ref<'loading' | 'ready' | 'failed'>('loading')
const sections = computed(() => todoSections<Task>({ rows: rows.value, late: late.value, range: range.value, now: Date.now(), keepEmpty: props.view === 'day' }))

/* the mock workspace's issues store is bound by whoever reads it first (as
   pages/issues.vue and TopicIssueChips do); lazily, so the mock code never
   rides a live build's chunk */
let bound: Promise<void> | null = null
const bindMock = () => (bound ||= api.mock
  ? import('~/utils/issues.mjs').then((m) => api.bindIssuesMock((me: string) => m.createMockIssues({ me })))
  : Promise.resolve())

const read = (filter: Record<string, unknown> | null) =>
  (filter ? api.listIssues({ filter }).then((r: { issues?: Task[] }) => (Array.isArray(r?.issues) ? r.issues : [])) : Promise.resolve([]))

let seq = 0
/* GET /v1/issues for the range and, when it holds today, the overdue ones;
   a quiet re-read (live, focus) keeps the list on screen while it runs */
async function load(quiet = false) {
  const mineSeq = ++seq
  const f = taskFilters({ range: range.value, today: props.today, mine: mine.value })
  if (!quiet) state.value = 'loading'
  try {
    await bindMock()
    const [a, b] = await Promise.all([read(f?.window ?? null), read(f?.overdue ?? null)])
    if (mineSeq !== seq) return
    rows.value = a
    late.value = b
    state.value = 'ready'
  } catch {
    if (mineSeq !== seq || quiet) return
    rows.value = []
    late.value = []
    state.value = 'failed'
  }
}
watch(() => [range.value?.from, range.value?.to, mine.value], () => { void load() })

/* frames come in bursts: one re-read after the last of them */
let timer: ReturnType<typeof setTimeout> | undefined
const soon = () => {
  clearTimeout(timer)
  timer = setTimeout(() => { void load(true) }, 500)
}
let offs: (() => unknown)[] = []
onMounted(() => {
  void load()
  offs = [live.onIssue(soon), live.onReconnected(soon)]
  window.addEventListener(CALENDAR_CHANGED_EVENT, soon)
  window.addEventListener('focus', soon)
})
onBeforeUnmount(() => {
  clearTimeout(timer)
  for (const off of offs) off()
  window.removeEventListener(CALENDAR_CHANGED_EVENT, soon)
  window.removeEventListener('focus', soon)
})
</script>

<style scoped>
.cal-todo {
  display: flex;
  flex-direction: column;
  gap: 12px;
  max-width: 56rem;
  padding: 12px 16px 24px;
}
.cal-todo__head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px; }
.cal-todo__title { margin: 0; font-size: 1rem; font-weight: 600; }
.cal-todo__chips { display: inline-flex; gap: 4px; }
.cal-todo__chip {
  min-height: 2rem;
  padding: 2px 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  font-size: 0.8125rem;
  cursor: pointer;
}
.cal-todo__chip:hover { background: var(--color-surface-hover); }
.cal-todo__chip:focus-visible { outline: 2px solid var(--color-accent); outline-offset: 1px; }
.cal-todo__chip[aria-pressed='true'] { border-color: var(--color-accent); background: var(--color-selected); font-weight: 600; }
.cal-todo__day { display: flex; flex-direction: column; gap: 4px; }
.cal-todo__dayhead {
  display: flex;
  align-items: baseline;
  gap: 6px;
  margin: 0;
  font-size: 0.8125rem;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.cal-todo__day--overdue .cal-todo__dayhead { color: var(--color-danger); }
.cal-todo__tag {
  padding: 0 6px;
  border-radius: var(--radius-sm);
  background: var(--color-selected);
  font-size: 0.75rem;
}
.cal-todo__none, .cal-todo__empty { margin: 0; font-size: 0.8125rem; }
.cal-todo__list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.cal-todo__link {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 4px 10px;
  padding: 6px 8px;
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  color: var(--color-fg);
  font-size: 0.8125rem;
  text-decoration: none;
  overflow-wrap: anywhere;
}
.cal-todo__day--overdue .cal-todo__link { box-shadow: inset 3px 0 0 var(--color-danger); }
.cal-todo__link:hover { background: var(--color-surface-hover); }
.cal-todo__link:focus-visible { outline: 2px solid var(--color-accent); outline-offset: 1px; }
.cal-todo__time, .cal-todo__key { font-variant-numeric: tabular-nums; white-space: nowrap; }
.cal-todo__key { font-weight: 600; }
.cal-todo__name { flex: 1 1 12rem; min-width: 0; }
.cal-todo__meta { color: var(--color-muted); font-size: 0.75rem; white-space: nowrap; }
</style>
