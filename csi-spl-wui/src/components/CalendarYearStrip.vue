<!-- spec 089 T007: the Calendar section's year strip. 36 mini-months - the
     previous, the current and the next year - in one scrolling column that
     stops at the three-year ends (spec 2.1). Days with events carry a dot and
     official days a tint, both from GET /v1/calendar/marks (spec 6.1.2); a
     click on a day moves the main view to that day's week ('pick').
     Our own Vue and date arithmetic (utils/calendar-year.mjs), no library.
     One tab stop: the arrow keys move between days, Enter or Space picks. -->
<template>
  <nav
    class="cal-strip"
    data-test="calendar-year-strip"
    :data-state="state"
    :aria-label="t('calendar.year_strip')"
  >
    <div ref="scrollEl" class="cal-strip__scroll" @keydown="onKey">
      <template v-for="m in months" :key="m.key">
        <h3 v-if="m.month0 === 0" class="cal-strip__year" :data-test="'calendar-year-' + m.year">{{ m.year }}</h3>
        <section class="cal-month" :data-month="m.key" data-test="calendar-month">
          <h4 class="cal-month__name">{{ monthName(m) }}</h4>
          <div class="cal-month__grid" role="grid" :aria-label="monthName(m) + ' ' + m.year">
            <span v-for="w in weekdayNames" :key="w.key" class="cal-month__wd" aria-hidden="true">{{ w.label }}</span>
            <span v-for="n in m.lead" :key="'lead-' + n" class="cal-day cal-day--blank" aria-hidden="true" />
            <button
              v-for="day in m.days"
              :key="day.iso"
              type="button"
              class="cal-day"
              :class="{
                'cal-day--today': day.iso === today,
                'cal-day--week': inWeek(day.iso),
                'cal-day--official': marks.official.has(day.iso),
              }"
              data-test="calendar-day"
              :data-day="day.iso"
              :data-count="marks.days.get(day.iso)?.count || undefined"
              :data-official="marks.official.has(day.iso) ? '1' : undefined"
              :tabindex="day.iso === cursor ? 0 : -1"
              :aria-label="dayLabel(day.iso)"
              :aria-current="day.iso === today ? 'date' : undefined"
              :title="dayLabel(day.iso)"
              @click="pick(day.iso)"
              @focus="cursor = day.iso"
            >
              {{ day.d }}
              <span v-if="marks.days.has(day.iso)" class="cal-day__dot" data-test="calendar-dot" aria-hidden="true" />
            </button>
          </div>
        </section>
      </template>
    </div>
  </nav>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { calAddDays, calMarks, calMarksQuery, calStripMonths, calStripYears, calWeekDays, calWeekStart, calWeekday, type CalMarks, type CalMonth } from '~/utils/calendar-year.mjs'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { hubJsonHeaders } from '~/utils/hub-headers'

const props = defineProps<{
  /** the UTC day 'YYYY-MM-DD' the main view shows; its week is highlighted */
  focus: string
  /** today, UTC 'YYYY-MM-DD' */
  today: string
}>()
const emit = defineEmits<{ pick: [iso: string] }>()

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

const years = computed(() => calStripYears(props.today))
const months = computed(() => calStripMonths(years.value))
const first = computed(() => months.value[0]?.days[0]?.iso || '')
const last = computed(() => months.value.at(-1)?.days.at(-1)?.iso || '')
const week = computed(() => new Set(calWeekDays(props.focus)))
const cursor = ref(props.focus || props.today)
watch(() => props.focus, (d) => { if (d) cursor.value = d })

function inWeek(iso: string) {
  return week.value.has(iso)
}

/* names from the catalogue (calendar.months / weekdays): a date itself is
   always YYYY-MM-DD (utils/date-iso.mjs), in every UI locale */
function monthName(m: CalMonth) {
  return t('calendar.months.m' + (m.month0 + 1))
}
/* Monday first */
const weekdayNames = computed(() => Array.from({ length: 7 }, (_, i) => ({ key: i, label: t('calendar.weekdays_narrow.d' + (i + 1)) })))

type Marks = CalMarks
const marks = shallowRef<Marks>(calMarks(null))
const state = ref<'loading' | 'ready' | 'failed'>('loading')

function dayLabel(iso: string) {
  const parts = [t('calendar.weekdays.d' + calWeekday(iso)) + ' ' + iso]
  const n = marks.value.days.get(iso)?.count || 0
  if (n) parts.push(t('calendar.events_n', { n }))
  const official = marks.value.official.get(iso)
  if (official) parts.push(official)
  return parts.join(', ')
}

/* GET /v1/calendar/marks for the strip's years (6.1.2). The mock workspace
   answers from calendar-mock. A failure leaves the strip without marks. */
async function loadMarks() {
  const q = calMarksQuery(years.value)
  try {
    let body: unknown
    if (api.mock) {
      const { mockCalendarMarks } = await import('~/utils/calendar-mock.mjs')
      body = mockCalendarMarks(Math.min(...years.value), Math.max(...years.value), props.today)
    } else {
      const headers = hubJsonHeaders(api.token)
      const r = await fetch(`${api.base}/v1/calendar/marks?${q}`, { credentials: api.credentials, headers, signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
      if (!r.ok) throw new Error('calendar marks ' + r.status)
      body = await r.json()
    }
    marks.value = calMarks(body)
    state.value = 'ready'
  } catch {
    state.value = 'failed'
  }
}

function pick(iso: string) {
  cursor.value = iso
  emit('pick', iso)
}

const KEY_STEP: Record<string, number> = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 }
function onKey(e: KeyboardEvent) {
  let next = ''
  if (e.key in KEY_STEP) next = calAddDays(cursor.value, KEY_STEP[e.key] ?? 0)
  else if (e.key === 'Home') next = calWeekStart(cursor.value)
  else if (e.key === 'End') next = calAddDays(calWeekStart(cursor.value), 6)
  else return
  e.preventDefault()
  if (!next || next < first.value || next > last.value) return
  cursor.value = next
  void nextTick(() => scrollEl.value?.querySelector<HTMLElement>(`[data-day="${next}"]`)?.focus())
}

/* open on the focused day's month, at the top of the column */
const scrollEl = ref<HTMLElement | null>(null)
function showMonth(iso: string) {
  const box = scrollEl.value
  const el = box?.querySelector<HTMLElement>(`[data-month="${iso.slice(0, 7)}"]`)
  if (box && el) box.scrollTop = el.offsetTop - box.offsetTop
}
onMounted(() => {
  showMonth(props.focus || props.today)
  void loadMarks()
})
</script>

<style scoped>
.cal-strip {
  display: flex;
  flex-direction: column;
  min-height: 0;
  height: 100%;
  border-inline-end: 1px solid var(--color-border);
}
.cal-strip__scroll {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  overscroll-behavior: contain;
  padding: 4px 10px 12px;
}
.cal-strip__year {
  position: sticky;
  top: 0;
  z-index: 1;
  margin: 0;
  padding: 6px 0 4px;
  font-size: 0.875rem;
  font-weight: 700;
  background: var(--color-bg);
}
.cal-month { margin: 0 0 10px; }
.cal-month__name {
  margin: 6px 0 2px;
  font-size: 0.75rem;
  font-weight: 600;
  text-transform: capitalize;
}
.cal-month__grid {
  display: grid;
  grid-template-columns: repeat(7, minmax(0, 1fr));
  gap: 1px;
}
.cal-month__wd {
  font-size: 0.625rem;
  text-align: center;
  color: var(--color-muted);
}
.cal-day {
  position: relative;
  min-width: 0;
  height: 24px;
  padding: 0;
  font: inherit;
  font-size: 0.6875rem;
  color: var(--color-fg);
  background: none;
  border: 0;
  border-radius: var(--radius-sm);
  cursor: pointer;
}
.cal-day--blank { cursor: default; }
.cal-day:hover { background: var(--color-surface-hover); }
.cal-day--official { background: color-mix(in srgb, var(--color-accent) 14%, transparent); }
.cal-day--week { background: color-mix(in srgb, var(--color-accent) 24%, transparent); }
.cal-day--today { font-weight: 700; color: var(--color-accent); }
.cal-day__dot {
  position: absolute;
  bottom: 2px;
  left: 50%;
  width: 4px;
  height: 4px;
  margin-left: -2px;
  border-radius: 50%;
  background: var(--color-accent);
}
</style>
