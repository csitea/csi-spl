<!-- spec 106 T005: the phone calendar's Month view (spec 4.2, FR-003), one
     page of CalendarPhone's page turn and loaded on its first show. A 6x7
     Monday-first grid (T002's calPhoneMonthGrid) that fills the scroller's
     16 px gutters with no gap between cells; each day has up to 3 colour
     dots, then `+n` (every day an event covers gets its dot; all-day events
     by their UTC date, S4-3). Today is raised, outlined and bold (never
     colour alone, 1.4.1). Under the grid, the agenda of the selected day:
     an event card opens its peek in one tap, an empty day offers
     `+ Add event` (S2-3). A tap on a day selects it; a second tap opens
     it in Day. A `role="grid"` whose cells say their event count, with the
     arrow keys moving between days (S4-2). -->
<template>
  <div class="calmonth" data-test="calphone-month" :data-period="grid[0]?.iso || ''" :data-day="day">
    <div
      class="calmonth__grid"
      role="grid"
      data-test="calphone-month-grid"
      :aria-label="monthTitle"
      @keydown="onKey"
    >
      <div class="calmonth__row calmonth__row--head" role="row">
        <span v-for="w in names.weekdays" :key="w" class="calmonth__wd" role="columnheader">{{ w }}</span>
      </div>
      <div v-for="(row, ri) in rows" :key="ri" class="calmonth__row" role="row">
        <div
          v-for="c in row"
          :key="c.iso"
          role="gridcell"
          class="calmonth__cell"
          :class="{
            'calmonth__cell--out': !c.inMonth,
            'calmonth__cell--today': c.iso === today,
            'calmonth__cell--on': c.iso === day,
          }"
          data-test="calphone-month-cell"
          :data-iso="c.iso"
          :data-count="countOf(c.iso)"
          :aria-selected="c.iso === day ? 'true' : 'false'"
          :aria-current="c.iso === today ? 'date' : undefined"
          :aria-label="cellName(c.iso)"
          :tabindex="interactive && c.iso === day ? 0 : -1"
          @click="tap(c.iso)"
        >
          <span class="calmonth__num" aria-hidden="true">{{ c.d }}</span>
          <span class="calmonth__dots" aria-hidden="true">
            <span
              v-for="ev in dotsOf(c.iso)"
              :key="ev.id"
              class="calmonth__dot"
              data-test="calphone-month-dot"
              :style="dotStyle(ev)"
            />
            <span v-if="countOf(c.iso) > MAX_DOTS" class="calmonth__more" data-test="calphone-month-more">+{{ countOf(c.iso) - MAX_DOTS }}</span>
          </span>
        </div>
      </div>
    </div>

    <section v-if="interactive" class="calmonth__agenda" data-test="calphone-month-agenda" :data-day="day">
      <h2 class="calmonth__agenda-title">{{ dayName(day) }}</h2>
      <p v-if="state === 'failed'" class="calmonth__note">{{ t('calendar.load_failed') }}</p>
      <ul v-else-if="agenda.length" class="calmonth__list">
        <li v-for="ev in agenda" :key="ev.id">
          <button
            type="button"
            class="calmonth__card"
            data-test="calphone-month-event"
            :data-id="ev.id"
            :aria-label="`${ev.title} - ${timeOf(ev)}`"
            @click="emit('open', ev)"
          >
            <span class="calmonth__dot calmonth__card-dot" aria-hidden="true" :style="dotStyle(ev)" />
            <span class="calmonth__card-time">{{ timeOf(ev) }}</span>
            <span class="calmonth__card-title">{{ ev.title }}</span>
          </button>
        </li>
      </ul>
      <p v-else-if="state === 'ready'" class="calmonth__empty" data-test="calphone-month-empty">
        <span>{{ t('calendar_phone.month_empty') }}</span>
        <span aria-hidden="true">·</span>
        <button type="button" class="calmonth__add" data-test="calphone-month-add" @click="emit('add', day)">
          <UiIcon name="plus" :size="16" />
          <span>{{ t('calendar_phone.month_add') }}</span>
        </button>
      </p>
    </section>
  </div>
</template>

<script setup lang="ts">
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { calAddDays, calWeekday } from '~/utils/calendar-year.mjs'
import { isoDateTimeIn } from '~/utils/date-iso-zone.mjs'
import { calPhoneEventDays, calPhoneMonthGrid, calPhoneTitle } from '~/utils/calendar-phone-nav.mjs'
import { CAL_COLORS } from '~/utils/calendar-event-form.mjs'

/* `day` is the selected day (the shell's shown day); a neighbour page
   during a turn is not `interactive`: its grid only, no agenda */
const props = defineProps<{
  day: string
  today: string
  items: CalendarItem[]
  state: 'loading' | 'ready' | 'failed'
  interactive: boolean
}>()
const emit = defineEmits<{ select: [day: string], openDay: [day: string], open: [ev: CalendarItem], add: [day: string] }>()

const { t } = useI18n({ useScope: 'global' })
const MAX_DOTS = 3

const names = computed(() => ({
  months: Array.from({ length: 12 }, (_, i) => t(`calendar.months.m${i + 1}`)),
  weekdays: Array.from({ length: 7 }, (_, i) => t(`calendar.weekdays.d${i + 1}`)),
}))
const monthTitle = computed(() => calPhoneTitle('month', props.day, names.value))
const dayName = (iso: string) => `${names.value.weekdays[calWeekday(iso) - 1] || ''} ${iso}`

const grid = computed(() => calPhoneMonthGrid(props.day))
const rows = computed(() => Array.from({ length: 6 }, (_, r) => grid.value.slice(r * 7, r * 7 + 7)))

/* each day's events, all-day first, then by start; a multi-day event on
   every day it covers (S4-3) */
const byDay = computed(() => {
  const out = new Map<string, CalendarItem[]>()
  const first = grid.value[0]?.iso || ''
  const last = grid.value[41]?.iso || ''
  for (const ev of props.items) {
    for (const d of calPhoneEventDays(ev)) {
      if (d < first || d > last) continue
      const list = out.get(d)
      if (list) list.push(ev)
      else out.set(d, [ev])
    }
  }
  for (const list of out.values()) {
    list.sort((a, b) => Number(b.all_day) - Number(a.all_day) || a.starts_at.localeCompare(b.starts_at) || a.id.localeCompare(b.id))
  }
  return out
})
const countOf = (iso: string) => byDay.value.get(iso)?.length || 0
const dotsOf = (iso: string) => (byDay.value.get(iso) || []).slice(0, MAX_DOTS)
const agenda = computed(() => byDay.value.get(props.day) || [])

const cellName = (iso: string) => `${dayName(iso)}, ${t('calendar.events_n', { n: countOf(iso) })}`
const dotStyle = (ev: CalendarItem) => (ev.color && CAL_COLORS.includes(ev.color) ? { '--dot': `var(--cal-color-${ev.color})` } : undefined)

function timeOf(ev: CalendarItem): string {
  if (ev.all_day) return t('calendar_reminder.all_day')
  const s = isoDateTimeIn(ev.starts_at, '')
  const e = isoDateTimeIn(ev.ends_at, '')
  if (!s) return ''
  /* an event that started on an earlier day shows its start date */
  const from = s.slice(0, 10) === props.day ? s.slice(11, 16) : `${s.slice(0, 10)} ${s.slice(11, 16)}`
  if (!e || e === s) return from
  return `${from} - ${e.slice(0, 10) === s.slice(0, 10) ? e.slice(11, 16) : `${e.slice(0, 10)} ${e.slice(11, 16)}`}`
}

/* S2-3: a tap selects the day; a tap on the selected day opens Day */
function tap(iso: string) {
  if (!props.interactive) return
  if (iso === props.day) emit('openDay', iso)
  else emit('select', iso)
}

/* S4-2: arrows move a day / a week (rtl: Left is forward), Home / End the
   week's ends, Enter / Space open the day; focus follows the selection,
   onto the next month's page when it leaves this one */
const root = getCurrentInstance()
function onKey(e: KeyboardEvent) {
  if (!props.interactive) return
  if (e.key === 'Enter' || e.key === ' ') {
    e.preventDefault()
    emit('openDay', props.day)
    return
  }
  const rtl = document.documentElement.dir === 'rtl'
  const wd = calWeekday(props.day)
  const steps: Record<string, number> = {
    ArrowRight: rtl ? -1 : 1,
    ArrowLeft: rtl ? 1 : -1,
    ArrowDown: 7,
    ArrowUp: -7,
    Home: 1 - wd,
    End: 7 - wd,
  }
  const step = steps[e.key]
  if (step === undefined) return
  e.preventDefault()
  if (!step) return
  const target = calAddDays(props.day, step)
  emit('select', target)
  const focus = (tries: number) => {
    const el = root?.proxy?.$el as HTMLElement | undefined
    const page = el?.isConnected ? el : document.querySelector('[data-test=calphone-page][data-dir="0"] [data-test=calphone-month]')
    const cell = page?.querySelector<HTMLElement>(`[data-test=calphone-month-cell][data-iso="${target}"]`)
    if (cell && cell.tabIndex === 0) cell.focus()
    else if (tries > 0) requestAnimationFrame(() => focus(tries - 1))
  }
  void nextTick(() => focus(30))
}
</script>

<style scoped>
.calmonth { min-width: 0; }

/* ---- the grid: the scroller's 16 px gutters, no gap (S4-9) ---- */
.calmonth__grid { min-width: 0; }
.calmonth__row {
  display: grid;
  grid-template-columns: repeat(7, minmax(0, 1fr));
  gap: 0;
}
.calmonth__wd {
  padding: 0 0 4px;
  font-size: 0.75rem;
  color: var(--color-muted);
  text-align: center;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.calmonth__cell {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: flex-start;
  gap: 4px;
  min-width: var(--tap);
  min-height: calc(var(--tap) + 4px);
  padding: 4px 0;
  box-sizing: border-box;
  border-radius: var(--radius);
  color: var(--color-fg);
  cursor: pointer;
  overflow: hidden;
  -webkit-tap-highlight-color: transparent;
}
.calmonth__cell--out { color: var(--color-muted); }
/* the other months' days: --color-muted alone is an AA text colour, nearly
   as dark as this month's on light; 0.7 on top keeps >= 3:1 on --color-bg
   in every theme (light 3.2, dark 4.4) and dims the dots too. A selected
   or today cell keeps its own look. */
.calmonth__cell--out:not(.calmonth__cell--on):not(.calmonth__cell--today) .calmonth__num,
.calmonth__cell--out:not(.calmonth__cell--on):not(.calmonth__cell--today) .calmonth__dots { opacity: 0.7; }
.calmonth__cell--on { background: var(--color-selected); }
/* today: raised, outlined in the accent, a bold number (1.4.1) */
.calmonth__cell--today {
  background: var(--color-surface);
  box-shadow: var(--focus-3d), var(--bevel-shine), var(--bevel-shade);
  outline: var(--focus-ring-w) solid var(--color-accent);
  outline-offset: calc(-1 * var(--focus-ring-w));
}
.calmonth__cell--today.calmonth__cell--on { background: var(--color-selected); }
.calmonth__cell--today .calmonth__num {
  font-weight: 700;
  color: var(--color-heading);
}
.calmonth__cell:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: calc(-1 * var(--focus-ring-w));
}
.calmonth__num {
  font-size: 0.875rem;
  line-height: 1.2;
}
.calmonth__dots {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 3px;
  min-height: 8px;
  max-width: 100%;
}
/* S4-8: a dot keeps 3:1 on light themes through its ring */
.calmonth__dot {
  flex: 0 0 auto;
  width: 6px;
  height: 6px;
  border-radius: var(--radius-pill);
  background: var(--dot, var(--color-accent));
  box-shadow: var(--cal-dot-ring);
}
.calmonth__more {
  font-size: 0.625rem;
  line-height: 1;
  color: var(--color-muted);
}

/* ---- the selected day's agenda ---- */
.calmonth__agenda { margin-top: 12px; }
.calmonth__agenda-title {
  margin: 0 0 8px;
  font-size: 0.875rem;
  font-weight: 600;
  color: var(--color-heading);
}
.calmonth__list {
  margin: 0;
  padding: 0;
  list-style: none;
}
.calmonth__card {
  display: grid;
  grid-template-columns: auto auto minmax(0, 1fr);
  align-items: center;
  gap: 8px;
  width: 100%;
  min-height: var(--tap);
  margin-bottom: 6px;
  padding: 6px 12px;
  box-sizing: border-box;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  background: var(--color-surface);
  box-shadow: var(--focus-3d), var(--bevel-shine), var(--bevel-shade);
  color: var(--color-fg);
  font: inherit;
  font-size: 0.875rem;
  text-align: start;
  cursor: pointer;
}
.calmonth__card:active {
  transform: translateY(1px);
  background: var(--color-selected);
  box-shadow: var(--bevel-shade);
}
.calmonth__card-dot { width: 8px; height: 8px; }
.calmonth__card-time {
  color: var(--color-muted);
  font-size: 0.75rem;
  white-space: nowrap;
}
/* S4-5: two lines, never wider than the card */
.calmonth__card-title {
  min-width: 0;
  overflow: hidden;
  overflow-wrap: anywhere;
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  line-clamp: 2;
}
.calmonth__note,
.calmonth__empty {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;
  margin: 0;
  font-size: 0.875rem;
  color: var(--color-muted);
}
.calmonth__add {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  min-width: var(--tap);
  min-height: var(--tap);
  padding: 0 12px;
  box-sizing: border-box;
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  background: var(--color-surface);
  color: var(--color-fg);
  font: inherit;
  font-size: 0.875rem;
  cursor: pointer;
}
.calmonth button:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}

@media (prefers-reduced-motion: reduce) {
  .calmonth__card:active { transform: none; }
}
</style>
