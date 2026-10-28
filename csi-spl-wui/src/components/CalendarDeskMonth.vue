<!-- SPL-4060 (owner HUM-10, t1 080e1f77 msg 396e95d3): the desktop
     calendar's Month view, beside Day, 3 days and Week in the vertical tab
     group. A 6x7 Monday-first grid (calPhoneMonthGrid); each day lists its
     first MAX items (time and title, in the event's colour) and `+n`. The
     day number opens that day in Day; an item opens its pop-over; a click
     on the rest of a day opens a new event there, as on the week. Part of
     CalendarMainView's lazy chunk. -->
<template>
  <div class="cal-month" data-test="calendar-month-grid" role="grid" :aria-label="title">
    <div class="cal-month__row cal-month__row--head" role="row">
      <span v-for="d in 7" :key="d" class="cal-month__wd" role="columnheader">{{ t('calendar.weekdays.d' + d) }}</span>
    </div>
    <div v-for="(row, ri) in rows" :key="ri" class="cal-month__row" role="row">
      <div
        v-for="c in row"
        :key="c.iso"
        role="gridcell"
        class="cal-month__cell"
        :class="{ 'cal-month__cell--out': !c.inMonth, 'cal-month__cell--today': c.iso === today }"
        data-test="calendar-month-cell"
        :data-day="c.iso"
        :aria-current="c.iso === today ? 'date' : undefined"
        @click="emit('create', c.iso)"
      >
        <button
          type="button"
          class="cal-month__num"
          data-test="calendar-month-day"
          :aria-label="`${c.iso} - ${t('calendar.events_n', { n: (byDay.get(c.iso) || []).length })}`"
          @click.stop="emit('day', c.iso)"
        >{{ c.d }}</button>
        <ul class="cal-month__list">
          <li v-for="ev in (byDay.get(c.iso) || []).slice(0, MAX)" :key="ev.id">
            <button
              type="button"
              v-bind="attrs(ev)"
              @click.stop="emit('open', ev)"
            >
              <span v-if="!ev.all_day" class="cal-month__time" dir="ltr">{{ isoClock(ev.starts_at) }}</span>
              <span class="cal-week__title">{{ ev.title }}</span>
            </button>
          </li>
        </ul>
        <button
          v-if="(byDay.get(c.iso) || []).length > MAX"
          type="button"
          class="cal-month__more"
          data-test="calendar-month-more"
          @click.stop="emit('day', c.iso)"
        >+{{ (byDay.get(c.iso) || []).length - MAX }}</button>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { isoClock } from '~/utils/date-iso.mjs'
import { calPhoneMonthGrid } from '~/utils/calendar-phone-nav.mjs'

const props = defineProps<{
  focus: string
  today: string
  byDay: Map<string, CalendarItem[]>
  attrs: (ev: CalendarItem) => Record<string, unknown>
}>()
const emit = defineEmits<{ day: [iso: string], create: [iso: string], open: [ev: CalendarItem] }>()
const { t } = useI18n({ useScope: 'global' })

const MAX = 3
const title = computed(() => props.focus.slice(0, 7))
const rows = computed(() => {
  const g = calPhoneMonthGrid(props.focus)
  return Array.from({ length: 6 }, (_, i) => g.slice(i * 7, i * 7 + 7))
})
</script>

<style scoped>
.cal-month {
  display: grid;
  grid-template-rows: auto repeat(6, minmax(0, 1fr));
  flex: 1 1 auto;
  min-height: 0;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  overflow: auto;
}
.cal-month__row { display: grid; grid-template-columns: repeat(7, minmax(0, 1fr)); min-height: 5.5rem; }
.cal-month__row--head { min-height: 0; }
.cal-month__wd {
  padding: 4px 6px;
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--color-muted);
  border-bottom: 1px solid var(--color-border);
}
.cal-month__cell {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
  padding: 2px 4px 4px;
  border-top: 1px solid var(--color-border);
  border-inline-start: 1px solid var(--color-border);
  cursor: pointer;
}
.cal-month__cell:first-child { border-inline-start: 0; }
.cal-month__cell--out { background: var(--color-bg-2); }
.cal-month__cell--out .cal-month__num { color: var(--color-muted); }
.cal-month__num {
  align-self: flex-start;
  min-width: 1.75rem;
  min-height: 1.75rem;
  padding: 0 4px;
  border: 0;
  border-radius: 50%;
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  font-size: 0.8125rem;
  cursor: pointer;
}
.cal-month__num:hover { background: var(--color-surface-hover); }
.cal-month__num:focus-visible { outline: 2px solid var(--color-accent); outline-offset: 1px; }
.cal-month__cell--today .cal-month__num { background: var(--color-accent); color: var(--color-on-accent); font-weight: 700; }
.cal-month__list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.cal-month__list .cal-week__item {
  display: flex;
  gap: 4px;
  width: 100%;
  border: 0;
  border-inline-start: 3px solid var(--cal-ev-color, var(--color-accent));
  /* the week block's tint (CalendarMainView .cal-ev): >= 4.5:1 for the text */
  background: color-mix(in srgb, var(--cal-ev-color, var(--color-accent)) 20%, var(--color-bg));
  color: var(--color-fg);
  font: inherit;
  font-size: 0.75rem;
  text-align: start;
  white-space: nowrap;
  overflow: hidden;
  cursor: pointer;
}
.cal-month__list .cal-week__title { overflow: hidden; text-overflow: ellipsis; font-weight: 600; }
.cal-month__time { font-variant-numeric: tabular-nums; }
.cal-month__more {
  align-self: flex-start;
  padding: 0 4px;
  border: 0;
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  font-size: 0.75rem;
  font-weight: 600;
  cursor: pointer;
}
.cal-month__more:hover { text-decoration: underline; }
</style>
