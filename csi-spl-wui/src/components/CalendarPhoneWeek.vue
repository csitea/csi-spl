<!-- spec 106 T006: the phone calendar's Week (FR-004, spec 4.2), inside a
     CalendarPhone page. A strip of seven day chips on top, then the seven
     days as an agenda list. A run of empty days folds into one thin row
     ("Thu-Sat: nothing planned"); a tap on it unfolds those days in place,
     each an empty row with a + (S2-7), and a chip scrolls the list to its day
     and unfolds it. A multi-day event lists under every day it covers as
     "Day X of Y", all-day ones by their UTC date (S4-3). The list opens at
     today. The strip turns with the page: the shell's swipe and < > step a
     week. Dates are T002's utils/calendar-phone-nav.mjs. -->
<template>
  <div class="calweek" data-test="calphone-week" :data-period="days[0]?.iso">
    <div class="calweek__strip" role="group" data-test="calweek-strip" :aria-label="t('calendar_phone_week.strip')">
      <button
        v-for="d in days"
        :key="d.iso"
        type="button"
        class="calweek__chip"
        :class="{ 'calweek__chip--today': d.iso === today, 'calweek__chip--busy': counts.get(d.iso) }"
        data-test="calweek-chip"
        :data-day="d.iso"
        :aria-label="chipLabel(d.iso, d.wd)"
        :aria-current="d.iso === today ? 'date' : undefined"
        @click="pickDay(d.iso)"
      >
        <span class="calweek__chip-wd">{{ weekdays[d.wd - 1] }}</span>
        <span class="calweek__chip-d">{{ d.d }}</span>
        <span class="calweek__chip-mark" aria-hidden="true" />
      </button>
    </div>

    <p v-if="state === 'failed'" class="calweek__note">{{ t('calendar.load_failed') }}</p>
    <ul v-else-if="state === 'ready'" class="calweek__list" data-test="calweek-list">
      <li
        v-for="row in rows"
        :key="row.kind === 'fold' ? `f:${row.from}` : `d:${row.iso}`"
        class="calweek__row"
        :data-test="`calweek-${row.kind}`"
        :data-day="row.kind === 'fold' ? row.from : row.iso"
        :data-to="row.kind === 'fold' ? row.to : undefined"
      >
        <button
          v-if="row.kind === 'fold'"
          type="button"
          class="calweek__fold"
          aria-expanded="false"
          @click="unfold(row.days)"
        >
          {{ t('calendar_phone_week.folded', { days: foldLabel(row) }) }}
        </button>
        <template v-else>
          <h3 class="calweek__day" :class="{ 'calweek__day--today': row.iso === today }">
            <span class="calweek__day-wd">{{ weekdays[calWeekday(row.iso) - 1] }}</span>
            <span class="calweek__day-iso">{{ row.iso }}</span>
            <span v-if="row.iso === today" class="calweek__day-today">{{ t('calendar_phone.today') }}</span>
          </h3>
          <CalendarHoursLine v-if="hoursLine(row.iso)" class="calweek__worked" compact :day="row.iso" :data="calHours?.index.value.get(row.iso)" @open="calHours?.open(row.iso)" />
          <div v-if="row.kind === 'empty'" class="calweek__empty">
            <span class="calweek__empty-text">{{ t('calendar_phone_week.empty') }}</span>
            <button
              type="button"
              class="calweek__add"
              data-test="calweek-add"
              :data-day="row.iso"
              :aria-label="t('calendar_phone_week.add_on', { day: row.iso })"
              :title="t('calendar_phone_week.add_on', { day: row.iso })"
              @click="emit('add', row.iso)"
            >
              <UiIcon name="plus" :size="20" />
            </button>
          </div>
          <ul v-else class="calweek__events">
            <li v-for="e in byDay.get(row.iso)" :key="e.ev.id">
              <button
                type="button"
                class="calweek__ev"
                data-test="calweek-event"
                :data-id="e.ev.id"
                :data-day="row.iso"
                @click="emit('open', e.ev)"
              >
                <span class="calweek__dot" :style="dotStyle(e.ev)" aria-hidden="true" />
                <span class="calweek__time">{{ e.time }}</span>
                <span class="calweek__title">{{ e.ev.title }}</span>
                <span v-if="e.span" class="calweek__span" data-test="calweek-span">{{ t('calendar_phone_week.span', e.span) }}</span>
              </button>
            </li>
          </ul>
        </template>
      </li>
    </ul>
  </div>
</template>

<script setup lang="ts">
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import type { Ref } from 'vue'
import { hoursShowsLine } from '~/utils/hours-calendar.mjs'
import type { HoursDay } from '~/composables/useCalendarHours'
import { CAL_COLORS } from '~/utils/calendar-event-form.mjs'
import { calWeekday } from '~/utils/calendar-year.mjs'
import { isoDateTimeIn } from '~/utils/date-iso-zone.mjs'
import { calPhoneEventDays, calPhoneFoldDays, calPhoneFoldLabel, calPhoneWeekStrip } from '~/utils/calendar-phone-nav.mjs'

type Fold = { kind: 'fold', from: string, to: string, days: string[] }
type Row = { kind: 'day' | 'empty', iso: string } | Fold
type Entry = { ev: CalendarItem, time: string, span: { n: number, of: number } | null, all: boolean }

const props = defineProps<{ day: string, today: string, items: CalendarItem[], state: string }>()

/* spec 107 v1.2 T011 (owner R9): the shell's hours (CalendarPhone provides
   them); a working day shows its Working hours line */
const calHours = inject<{ index: Ref<Map<string, HoursDay>>, open: (day: string) => void } | null>('calphone-hours', null)
const hoursLine = (iso: string) => Boolean(calHours && hoursShowsLine(iso, calHours.index.value))
const emit = defineEmits<{ open: [ev: CalendarItem], add: [day: string] }>()

const { t } = useI18n({ useScope: 'global' })

const weekdays = computed(() => Array.from({ length: 7 }, (_, i) => t(`calendar.weekdays.d${i + 1}`)))
const days = computed(() => calPhoneWeekStrip(props.day))

const dotStyle = (ev: CalendarItem) => (ev.color && CAL_COLORS.includes(ev.color) ? { background: `var(--cal-color-${ev.color})` } : undefined)

/* the time an event shows on one of its days: start-end on its only day,
   the start on its first, the end on its last, nothing in between */
function timeOn(ev: CalendarItem, list: string[], i: number): string {
  if (ev.all_day) return t('calendar_phone_week.all_day')
  const hm = (iso: string) => isoDateTimeIn(iso, '').slice(11, 16)
  const s = hm(ev.starts_at)
  const e = ev.ends_at && ev.ends_at !== ev.starts_at ? hm(ev.ends_at) : ''
  if (list.length <= 1) return e ? `${s}-${e}` : s
  if (i === 0) return s
  return i === list.length - 1 && e ? `-${e}` : ''
}

/* every day of the week -> the events covering it (S4-3): all-day and
   carried-over ones first, then by start */
const byDay = computed(() => {
  const week = new Set(days.value.map((d) => d.iso))
  const out = new Map<string, Entry[]>()
  for (const ev of props.items) {
    const list = calPhoneEventDays(ev, '')
    list.forEach((iso, i) => {
      if (!week.has(iso)) return
      const span = list.length > 1 ? { n: i + 1, of: list.length } : null
      out.set(iso, [...(out.get(iso) || []), { ev, time: timeOn(ev, list, i), span, all: ev.all_day || i > 0 }])
    })
  }
  for (const list of out.values()) {
    list.sort((a, b) => Number(b.all) - Number(a.all) || a.ev.starts_at.localeCompare(b.ev.starts_at) || a.ev.id.localeCompare(b.ev.id))
  }
  return out
})
const counts = computed(() => new Map([...byDay.value].map(([d, l]) => [d, l.length])))

/* the empty days a tap unfolded; today never folds, so the list opens on it */
const opened = ref(new Set<string>())
const rows = computed<Row[]>(() => {
  const open = new Set(opened.value)
  open.add(props.today)
  return calPhoneFoldDays(days.value.map((d) => d.iso), (d: string) => counts.value.get(d) || 0, open) as Row[]
})
const foldLabel = (row: Fold) => calPhoneFoldLabel(row, weekdays.value)

function chipLabel(iso: string, wd: number): string {
  const n = counts.value.get(iso) || 0
  const parts = [`${weekdays.value[wd - 1]} ${iso}`]
  if (iso === props.today) parts.push(t('calendar_phone.today'))
  parts.push(n ? t('calendar.events_n', { n }) : t('calendar_phone_week.empty'))
  return parts.join(', ')
}

function unfold(list: string[]) {
  opened.value = new Set([...opened.value, ...list])
}

const self = getCurrentInstance()
const rootEl = () => self?.proxy?.$el as HTMLElement | undefined
/** scroll the page's scroller so `iso`'s row sits just under the sticky strip */
function scrollTo(iso: string) {
  const el = rootEl()
  const row = el?.querySelector<HTMLElement>(`[data-test=calweek-list] > [data-day="${iso}"]`)
  const scroller = row?.closest<HTMLElement>('.calphone__scroll')
  if (!row || !scroller) return
  const strip = el?.querySelector<HTMLElement>('[data-test=calweek-strip]')
  const top = row.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop
  scroller.scrollTop = Math.max(0, top - (strip?.offsetHeight || 0) - 4)
}

/* a chip: unfold its day when it is folded, then scroll to it (S2-7) */
async function pickDay(iso: string) {
  if (!counts.value.get(iso)) unfold([iso])
  await nextTick()
  scrollTo(iso)
}

/* opened at today: once, on the first ready paint of the week holding it */
let placed = ''
watch(() => [props.state, props.day] as const, async ([state]) => {
  const week = days.value[0]?.iso || ''
  if (state !== 'ready' || placed === week) return
  placed = week
  if (!days.value.some((d) => d.iso === props.today)) return
  await nextTick()
  scrollTo(props.today)
}, { immediate: true })
</script>

<style scoped>
/* spec 107 v1.2 T011: the Working hours line */
.calweek__worked { margin-block: 4px 8px; }
.calweek { min-width: 0; }

/* ---- the strip: seven chips in one row, sticky over the list ---- */
.calweek__strip {
  position: sticky;
  top: -12px;
  z-index: 1;
  display: flex;
  gap: 2px;
  margin: -12px -4px 8px;
  padding: 12px 4px 6px;
  background: var(--color-bg);
  border-bottom: 1px solid var(--color-border);
}
.calweek__chip {
  position: relative;
  display: flex;
  flex: 1 1 0;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  min-width: 0;
  min-height: var(--tap);
  padding: 4px 0 8px;
  border: 1px solid transparent;
  border-radius: var(--radius);
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  line-height: 1.15;
  cursor: pointer;
}
.calweek__chip-wd {
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 0.75rem;
  color: var(--color-muted);
}
.calweek__chip-d { font-size: 1rem; font-weight: 600; }
.calweek__chip-mark {
  position: absolute;
  bottom: 3px;
  width: 5px;
  height: 5px;
  border-radius: var(--radius-pill);
  background: transparent;
}
.calweek__chip--busy .calweek__chip-mark {
  background: var(--color-accent);
  box-shadow: var(--cal-dot-ring);
}
.calweek__chip--today {
  border-color: var(--color-accent);
  background: var(--color-selected);
  box-shadow: var(--focus-3d), var(--bevel-shine), var(--bevel-shade);
}
.calweek__chip--today .calweek__chip-d { color: var(--color-accent); }

/* ---- the list ---- */
.calweek__note {
  margin: 0;
  font-size: 0.875rem;
  color: var(--color-muted);
}
.calweek__list,
.calweek__events {
  margin: 0;
  padding: 0;
  list-style: none;
}
.calweek__row { min-width: 0; margin-bottom: 8px; }
.calweek__day {
  display: flex;
  align-items: baseline;
  flex-wrap: wrap;
  gap: 0 8px;
  margin: 0 0 4px;
  font-size: 0.875rem;
  font-weight: 600;
  color: var(--color-heading);
}
.calweek__day-iso { font-weight: 400; color: var(--color-muted); }
.calweek__day--today .calweek__day-wd,
.calweek__day-today { color: var(--color-accent); }
.calweek__fold {
  display: flex;
  align-items: center;
  width: 100%;
  min-height: var(--tap);
  padding: 0 12px;
  box-sizing: border-box;
  border: 1px dashed var(--color-border);
  border-radius: var(--radius-md);
  background: transparent;
  color: var(--color-muted);
  font: inherit;
  font-size: 0.875rem;
  text-align: start;
  overflow-wrap: anywhere;
  cursor: pointer;
}
.calweek__empty {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: var(--tap);
  padding-inline-start: 12px;
  border: 1px dashed var(--color-border);
  border-radius: var(--radius-md);
  color: var(--color-muted);
  font-size: 0.875rem;
}
.calweek__empty-text { flex: 1 1 auto; min-width: 0; overflow-wrap: anywhere; }
.calweek__add {
  display: inline-grid;
  place-items: center;
  flex: 0 0 auto;
  width: var(--tap);
  height: var(--tap);
  padding: 0;
  border: 0;
  border-radius: var(--radius-pill);
  background: transparent;
  color: var(--color-accent);
  cursor: pointer;
}
.calweek__ev {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 2px 8px;
  width: 100%;
  min-height: var(--tap);
  margin-bottom: 6px;
  padding: 6px 12px;
  box-sizing: border-box;
  border: 0;
  border-radius: var(--radius-md);
  background: var(--color-surface);
  box-shadow: var(--focus-3d), var(--bevel-shine), var(--bevel-shade);
  color: var(--color-fg);
  font: inherit;
  font-size: 0.875rem;
  text-align: start;
  cursor: pointer;
}
.calweek__ev:active {
  transform: translateY(1px);
  background: var(--color-selected);
  box-shadow: var(--bevel-shade);
}
.calweek__dot {
  flex: 0 0 auto;
  width: 10px;
  height: 10px;
  border-radius: var(--radius-pill);
  background: var(--color-accent);
  box-shadow: var(--cal-dot-ring);
}
.calweek__time {
  flex: 0 0 auto;
  color: var(--color-muted);
  font-variant-numeric: tabular-nums;
}
.calweek__title {
  flex: 1 1 8em;
  min-width: 0;
  font-weight: 600;
  overflow-wrap: anywhere;
}
.calweek__span {
  flex: 0 0 auto;
  padding: 0 6px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  color: var(--color-muted);
  font-size: 0.75rem;
}

.calweek button:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}
@media (prefers-reduced-motion: reduce) {
  .calweek__ev:active { transform: none; }
}
</style>
