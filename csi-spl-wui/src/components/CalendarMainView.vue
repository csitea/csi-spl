<!-- spec 089 T007: the Calendar's main view, a PLACEHOLDER. T008 replaces this
     file with the library grid (Day / Week / Month, drag to move, the event
     dialog). Until then it shows the week holding `focus` - seven day columns
     with the items of GET /v1/calendar/events (spec 6.1.2) - and Today /
     previous / next, so the year strip has something to move (AC-04).
     Loaded as its own chunk by pages/calendar.vue (defineAsyncComponent).
     T009, phone (`phone`, <= 820 px, spec 2.2): opens on the Day view - the
     shown day only, previous / next step a day - and Week is the seven days
     as a list, one under another. Today / previous / next and Day | Week sit
     in a bar at the bottom, above the composer dock, where a thumb reaches. -->
<template>
  <section
    class="cal-main"
    :class="{ 'cal-main--phone': phone }"
    data-test="calendar-main"
    :data-week="weekStart"
    :data-day="focus"
    :data-view="view"
    :data-state="state"
  >
    <div class="cal-main__bar">
      <button type="button" class="btn ghost" data-test="calendar-today" @click="emit('move', today)">{{ t('calendar.today') }}</button>
      <button type="button" class="icon-btn" data-test="calendar-prev" :aria-label="prevLabel" :title="prevLabel" @click="step(-1)">
        <UiIcon name="chevron-left" :size="18" />
      </button>
      <button type="button" class="icon-btn" data-test="calendar-next" :aria-label="nextLabel" :title="nextLabel" @click="step(1)">
        <UiIcon name="chevron-right" :size="18" />
      </button>
      <h3 class="cal-main__range" data-test="calendar-range" aria-live="polite">{{ range }}</h3>
      <div v-if="phone" class="cal-main__views" role="group" :aria-label="t('calendar.view')">
        <button
          v-for="v in PHONE_VIEWS"
          :key="v"
          type="button"
          class="btn ghost cal-main__view"
          :data-test="'calendar-view-' + v"
          :aria-pressed="view === v ? 'true' : 'false'"
          @click="phoneView = v"
        >{{ t('calendar.view_' + v) }}</button>
      </div>
    </div>
    <p v-if="state === 'failed'" class="muted" role="alert" data-test="calendar-failed">{{ t('calendar.load_failed') }}</p>
    <div class="cal-week" data-test="calendar-week">
      <div
        v-for="day in shown"
        :key="day"
        class="cal-week__day"
        :class="{ 'cal-week__day--today': day === today }"
        data-test="calendar-week-day"
        :data-day="day"
      >
        <h4 class="cal-week__head">{{ dayHead(day) }}</h4>
        <ul class="cal-week__list">
          <li
            v-for="ev in byDay.get(day) || []"
            :key="ev.id"
            class="cal-week__item"
            data-test="calendar-item"
            :data-id="ev.id"
            :data-source="ev.source"
            :data-kind="ev.kind"
          >
            <span v-if="!ev.all_day" class="cal-week__time" dir="ltr">{{ isoClock(ev.starts_at) }}</span>
            <span class="cal-week__title">{{ ev.title }}</span>
            <span v-if="ev.release_version" class="cal-week__badge" dir="ltr">{{ ev.release_version }}</span>
          </li>
        </ul>
      </div>
    </div>
  </section>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { calAddDays, calWeekday, calWeekDays, calWeekStart } from '~/utils/calendar-year.mjs'
import { isoClock } from '~/utils/date-iso.mjs'
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { hubJsonHeaders } from '~/utils/hub-headers'

const props = defineProps<{ focus: string, today: string, phone?: boolean }>()
const emit = defineEmits<{ move: [iso: string] }>()

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

const weekStart = computed(() => calWeekStart(props.focus))
const days = computed(() => calWeekDays(props.focus))
/* a date is YYYY-MM-DD in every UI locale (utils/date-iso.mjs); the weekday
   name comes from the catalogue */
function dayHead(iso: string) {
  return `${t('calendar.weekdays.d' + calWeekday(iso))} ${iso.slice(5)}`
}
/* T009: a phone opens on Day; the desktop stays on its week (T008 brings
   its Day / Week / Month control) */
const PHONE_VIEWS = ['day', 'week'] as const
const phoneView = ref<'day' | 'week'>('day')
const view = computed(() => (props.phone ? phoneView.value : 'week'))
const shown = computed(() => (view.value === 'day' ? [props.focus] : days.value))
const prevLabel = computed(() => t(view.value === 'day' ? 'calendar.prev_day' : 'calendar.prev_week'))
const nextLabel = computed(() => t(view.value === 'day' ? 'calendar.next_day' : 'calendar.next_week'))
function step(dir: 1 | -1) {
  emit('move', view.value === 'day' ? calAddDays(props.focus, dir) : calAddDays(weekStart.value, dir * 7))
}

const range = computed(() => {
  if (view.value === 'day') return props.focus
  const d = days.value
  return d.length ? `${d[0]} – ${d[6]}` : ''
})

const items = shallowRef<CalendarItem[]>([])
const state = ref<'loading' | 'ready' | 'failed'>('loading')
/* each item on the UTC day it starts (an official day starts at 00:00 UTC) */
const byDay = computed(() => {
  const out = new Map<string, CalendarItem[]>()
  for (const ev of items.value) {
    const day = String(ev.starts_at || '').slice(0, 10)
    out.set(day, [...(out.get(day) || []), ev])
  }
  return out
})

let seq = 0
/* GET /v1/calendar/events for [Monday 00:00Z, next Monday 00:00Z) (6.1.2).
   The mock workspace answers from calendar-mock. */
async function load() {
  const mine = ++seq
  const start = `${weekStart.value}T00:00:00Z`
  const end = `${calAddDays(weekStart.value, 7)}T00:00:00Z`
  state.value = 'loading'
  try {
    let body: { events?: CalendarItem[] }
    if (api.mock) {
      const { mockCalendarEvents } = await import('~/utils/calendar-mock.mjs')
      body = mockCalendarEvents(start, end, props.today)
    } else {
      const headers = hubJsonHeaders(api.token)
      const q = new URLSearchParams({ start, end })
      const r = await fetch(`${api.base}/v1/calendar/events?${q}`, { credentials: api.credentials, headers, signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
      if (!r.ok) throw new Error('calendar events ' + r.status)
      body = await r.json()
    }
    if (mine !== seq) return
    items.value = Array.isArray(body?.events) ? body.events : []
    state.value = 'ready'
  } catch {
    if (mine !== seq) return
    items.value = []
    state.value = 'failed'
  }
}
watch(weekStart, () => { void load() })
onMounted(() => { void load() })
</script>

<style scoped>
.cal-main { display: flex; flex-direction: column; gap: 8px; padding: 8px 12px; min-width: 0; }
.cal-main__bar { display: flex; align-items: center; gap: 6px; }
.cal-main__range { margin: 0 0 0 8px; font-size: 1rem; font-weight: 600; }
.cal-week {
  display: grid;
  grid-template-columns: repeat(7, minmax(0, 1fr));
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  min-height: 320px;
}
.cal-week__day { min-width: 0; padding: 4px 6px; border-inline-start: 1px solid var(--color-border); }
.cal-week__day:first-child { border-inline-start: 0; }
.cal-week__day--today .cal-week__head { color: var(--color-accent); }
.cal-week__head { margin: 0 0 6px; font-size: 0.8125rem; font-weight: 600; text-transform: capitalize; }
.cal-week__list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.cal-week__item {
  display: flex; flex-wrap: wrap; gap: 4px; align-items: baseline;
  padding: 2px 4px; font-size: 0.75rem;
  background: var(--color-surface); border-radius: var(--radius-sm);
  overflow-wrap: anywhere;
}
.cal-week__time { color: var(--color-muted); }
.cal-week__badge { font-size: 0.6875rem; padding: 0 4px; border: 1px solid var(--color-border); border-radius: var(--radius-sm); }

/* T009 (spec 2.2): a phone - the days one under another in their own
   scroller, the bar at the bottom above the composer dock, 44 px targets */
.cal-main--phone { flex: 1 1 auto; min-height: 0; padding: 0; gap: 0; }
.cal-main--phone .cal-week {
  order: 1;
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  overscroll-behavior: contain;
  grid-template-columns: minmax(0, 1fr);
  align-content: start;
  margin: 8px;
}
.cal-main--phone .cal-week__day {
  padding: 8px 10px;
  border-inline-start: 0;
  border-top: 1px solid var(--color-border);
}
.cal-main--phone .cal-week__day:first-child { border-top: 0; }
.cal-main--phone .cal-week__head { font-size: 0.9375rem; }
.cal-main--phone .cal-week__item { font-size: 0.9375rem; padding: 8px 10px; }
.cal-main--phone .cal-week__badge { font-size: 0.8125rem; }
.cal-main--phone .cal-main__bar {
  order: 2;
  flex: 0 0 auto;
  flex-wrap: wrap;
  gap: 4px;
  padding: 6px 8px calc(6px + var(--composer-dock-h, 0px));
  border-top: 1px solid var(--color-border);
  background: var(--color-bg);
}
.cal-main--phone .cal-main__bar > .btn,
.cal-main--phone .cal-main__bar > .icon-btn,
.cal-main--phone .cal-main__view { min-height: var(--tap); min-width: var(--tap); }
.cal-main--phone .cal-main__range {
  order: -1;
  flex: 1 0 100%;
  margin: 0;
  padding: 0 4px;
  font-size: 0.875rem;
  text-align: center;
}
.cal-main--phone .cal-main__views { display: flex; gap: 2px; margin-inline-start: auto; }
.cal-main__view[aria-pressed='true'] { font-weight: 700; background: var(--color-surface); }
</style>
