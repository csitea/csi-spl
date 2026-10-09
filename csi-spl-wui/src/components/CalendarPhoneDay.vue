<!-- spec 106 T007: the phone calendar's Day view (FR-005, spec 4.2 Day),
     mounted by CalendarPhone.vue (T004) in its day slot, a lazy chunk of its
     own. No week strip: the title names the day and a swipe, < > or Week
     change it. On top the all-day row (UTC date, S4-3; two lines, then +n
     that expands in place); then the time grid: one 48 px row per local
     hour of the date (23 / 25 on DST days, the repeated hour labelled
     twice, S4-6), the now line, the timed events in at most 3 overlap
     columns (a 4th becomes a +n chip that opens the hour's list, S4-4),
     short events at least 26 px. It opens scrolled to the now line, else
     to the first event.
     A tap on empty time (< 8 px, < 300 ms, S2-2) emits `create` for that
     hour; a tap on an event emits `peek` (T009). A finger held > 400 ms on
     an event lifts it (097 hold-to-drag): it moves in time only, through
     utils/calendar-drag.mjs, and is saved with If-Match. -->
<template>
  <div ref="rootEl" class="calday" data-test="calphone-day" :data-day="day" :data-hours="hours.length">
    <CalendarHoursLine v-if="hoursLine(day)" class="calday__worked" compact :day="day" :data="calHours?.index.value.get(day)" @open="calHours?.open(day)" />
    <div v-if="allDay.length" class="calday__allday" data-test="calday-allday">
      <span class="calday__allday-label">{{ t('calendar_event.field_all_day') }}</span>
      <ul class="calday__allday-list">
        <li v-for="ev in allDayShown" :key="ev.id">
          <button
            type="button"
            class="calday__chip"
            data-test="calday-allday-item"
            :data-id="ev.id"
            :style="colorStyle(ev)"
            @click="emit('peek', ev)"
          >
            <span class="calday__dot" aria-hidden="true" />
            <span class="calday__chip-title">{{ ev.title }}</span>
          </button>
        </li>
      </ul>
      <button
        v-if="allDayMore > 0"
        type="button"
        class="calday__allday-more"
        data-test="calday-allday-more"
        :aria-label="t('calendar.events_n', { n: allDayMore })"
        :aria-expanded="allDayOpen ? 'true' : 'false'"
        @click="allDayOpen = true"
      >
        +{{ allDayMore }}
      </button>
    </div>

    <div
      ref="gridEl"
      class="calday__grid"
      data-test="calday-grid"
      role="group"
      :aria-label="t('calendar_phone.view_day')"
      :style="{ height: `${gridH}px` }"
      @pointerdown="onGridDown"
      @pointerup="onGridUp"
    >
      <button
        v-for="(h, i) in hours"
        :key="h.at"
        type="button"
        class="calday__hour"
        data-test="calday-hour"
        :data-label="h.label"
        :data-at="isoAt(h.at)"
        :style="{ top: `${i * HOUR_PX}px` }"
        :aria-label="`${t('calendar_phone.add')} ${h.label}`"
        @click="onHourClick($event, i)"
      >
        <span class="calday__hour-label" aria-hidden="true">{{ h.label }}</span>
      </button>

      <div v-if="nowY !== null" class="calday__now" data-test="calday-now" :style="{ top: `${nowY}px` }" aria-hidden="true" />

      <button
        v-for="b in blocks"
        :key="b.ev.id"
        type="button"
        class="calday__ev"
        :class="{
          'calday__ev--short': b.h < 44,
          'calday__ev--lifted': lifted === b.ev.id,
          'calday__ev--saving': saving === b.ev.id,
          'calday__ev--cont': b.cont,
        }"
        data-test="calday-event"
        :data-id="b.ev.id"
        :data-starts="b.ev.starts_at"
        :data-ends="b.ev.ends_at"
        :data-col="b.col"
        :data-cols="b.cols"
        :style="{ ...blockStyle(b), ...colorStyle(b.ev) }"
        :aria-label="`${b.time} ${b.ev.title}`"
        @pointerdown.stop="onEvDown($event, b.ev, b.top)"
        @click="onEvClick($event, b.ev)"
        @contextmenu="onContextMenu"
      >
        <span class="calday__dot" aria-hidden="true" />
        <span class="calday__ev-title">{{ b.ev.title }}</span>
        <span v-if="b.h >= 44" class="calday__ev-time" aria-hidden="true">{{ b.time }}</span>
      </button>

      <button
        v-for="c in chips"
        :key="`more:${c.top}`"
        type="button"
        class="calday__more"
        data-test="calday-more"
        :style="blockStyle({ top: c.top, h: MORE_PX, col: MAX_COLS - 1, cols: MAX_COLS })"
        :aria-label="t('calendar.events_n', { n: c.events.length })"
        :aria-expanded="list?.top === c.top ? 'true' : 'false'"
        @pointerdown.stop
        @click="list = list?.top === c.top ? null : c"
      >
        +{{ c.events.length }}
      </button>

      <div v-if="list" class="calday__list" data-test="calday-list" :style="{ top: `${list.top}px` }" @pointerdown.stop>
        <button
          v-for="ev in list.events"
          :key="ev.id"
          type="button"
          class="calday__list-row"
          data-test="calday-list-item"
          :data-id="ev.id"
          :style="colorStyle(ev)"
          @click="emit('peek', ev)"
        >
          <span class="calday__dot" aria-hidden="true" />
          <span class="calday__ev-title">{{ clockOf(ev.starts_at) }} {{ ev.title }}</span>
        </button>
      </div>
    </div>
    <p v-if="notice" class="calday__notice" role="status" data-test="calday-notice" :data-key="notice">{{ t(notice) }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import type { Ref } from 'vue'
import { hoursShowsLine } from '~/utils/hours-calendar.mjs'
import type { HoursDay } from '~/composables/useCalendarHours'
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { CAL_COLORS, calEditable } from '~/utils/calendar-event-form.mjs'
import { calendarUpdate } from '~/utils/calendar-events-api.mjs'
import { CALENDAR_CHANGED_EVENT } from '~/utils/calendar-reminders.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { isoClock } from '~/utils/date-iso.mjs'
import { isoSeconds } from '~/utils/iso-seconds.mjs'
import { CAL_DAY_MIN, CAL_DRAG_PX, CAL_SNAP_MIN, calDragErrorKey, calMinuteOf, calMoveTo, calSameTimes, calSnap } from '~/utils/calendar-drag.mjs'
import { calPhoneDayHours, calPhoneEventDays, calPhoneHourPreset } from '~/utils/calendar-phone-nav.mjs'
import { CAL_SWIPE_HOLD_MS, CAL_SWIPE_TAP_PX, calSwipeIsTap } from '~/utils/calendar-swipe.mjs'

type Times = { starts_at: string, ends_at: string }
type Block = { ev: CalendarItem, top: number, h: number, col: number, cols: number, cont: boolean, time: string }
type More = { top: number, events: CalendarItem[] }
export type CalPhoneCreate = { date: string, start: string, endDate: string, end: string, at: string, endAt: string }

const props = defineProps<{ day: string, today: string, items: CalendarItem[] }>()

/* spec 107 v1.2 T011 (owner R9): the shell's hours (CalendarPhone provides
   them); a working day shows its Working hours line */
const calHours = inject<{ index: Ref<Map<string, HoursDay>>, open: (day: string) => void } | null>('calphone-hours', null)
const hoursLine = (iso: string) => Boolean(calHours && hoursShowsLine(iso, calHours.index.value))
const emit = defineEmits<{ create: [slot: CalPhoneCreate], peek: [ev: CalendarItem] }>()

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

/* spec 4.2: 48 px an hour; a block under 30 minutes still 26 px (S4-4) */
const HOUR_PX = 48
const MIN_PX = 26
const MORE_PX = 44
const HOUR_MS = 3600000
const MAX_COLS = 3
const ALL_DAY_LINES = 2

const isoAt = (ms: number) => isoSeconds(new Date(ms))
const clockOf = (v: string) => isoClock(v) || ''

/* ---- the hours of this date in the viewer's zone (S4-6) ---- */
const hours = computed(() => calPhoneDayHours(props.day))
const gridH = computed(() => hours.value.length * HOUR_PX)
const dayStart = computed(() => hours.value[0]?.at ?? Number.NaN)
const dayEnd = computed(() => (hours.value.length ? hours.value[hours.value.length - 1]!.at + HOUR_MS : Number.NaN))

/** the grid's y of instant `t`, through the hour row it falls in (never local midnight + h * 48) */
function yOf(t: number): number {
  const rows = hours.value
  if (!rows.length) return 0
  let i = 0
  while (i + 1 < rows.length && rows[i + 1]!.at <= t) i++
  const y = i * HOUR_PX + ((t - rows[i]!.at) / HOUR_MS) * HOUR_PX
  return Math.min(gridH.value, Math.max(0, y))
}
/** the instant at grid y */
function atOf(y: number): number {
  const rows = hours.value
  const i = Math.min(rows.length - 1, Math.max(0, Math.floor(y / HOUR_PX)))
  return rows[i]!.at + ((y - i * HOUR_PX) / HOUR_PX) * HOUR_MS
}

const colorStyle = (ev: CalendarItem) => (ev.color && CAL_COLORS.includes(ev.color) ? { '--cal-ev-color': `var(--cal-color-${ev.color})` } : undefined)

/* ---- the all-day row: by UTC date (S4-3), two lines then +n ---- */
const allDayOpen = ref(false)
watch(() => props.day, () => { allDayOpen.value = false })
const allDay = computed(() => props.items.filter((ev) => ev.all_day && calPhoneEventDays(ev).includes(props.day)))
const allDayShown = computed(() => (allDayOpen.value || allDay.value.length <= ALL_DAY_LINES ? allDay.value : allDay.value.slice(0, ALL_DAY_LINES - 1)))
const allDayMore = computed(() => allDay.value.length - allDayShown.value.length)

/* ---- the timed events: overlap columns, capped at 3 (S4-4) ---- */
/* a lifted event shows where it would land; a saved one until the shell reads it back */
const preview = shallowRef<({ id: string } & Times) | null>(null)
function timesOf(ev: CalendarItem): Times {
  const p = preview.value
  return p && p.id === ev.id ? p : ev
}

/** the day's timed events as drawn boxes, top first, before columns */
function dayBoxes(): Block[] {
  const s0 = dayStart.value
  const e0 = dayEnd.value
  const boxes: Block[] = []
  if (Number.isNaN(s0)) return boxes
  for (const ev of props.items) {
    if (ev.all_day) continue
    const tm = timesOf(ev)
    const s = Date.parse(tm.starts_at)
    const e = Math.max(s, Date.parse(tm.ends_at) || s)
    if (Number.isNaN(s) || s >= e0 || (e <= s0 && !(e === s && s >= s0))) continue
    const top = Math.min(yOf(Math.max(s, s0)), gridH.value - MIN_PX)
    const h = Math.max(MIN_PX, yOf(Math.min(e, e0)) - top)
    boxes.push({ ev, top, h, col: 0, cols: 1, cont: s < s0 || e > e0, time: `${clockOf(tm.starts_at)}-${clockOf(tm.ends_at)}` })
  }
  return boxes.sort((a, b) => a.top - b.top || b.h - a.h || String(a.ev.id).localeCompare(String(b.ev.id)))
}

/* calDayLayout's clustering, on the drawn boxes so a short block keeps its
   26 px; a cluster wider than 3 shows two columns and a +n chip for the rest */
const layout = computed(() => {
  const shown: Block[] = []
  const chips: More[] = []
  let cluster: Block[] = []
  let ends: number[] = []
  let clusterEnd = -1
  const close = () => {
    if (ends.length > MAX_COLS) {
      const hidden = cluster.filter((b) => b.col >= MAX_COLS - 1)
      for (const b of cluster) if (b.col < MAX_COLS - 1) shown.push({ ...b, cols: MAX_COLS })
      chips.push({ top: Math.min(...hidden.map((b) => b.top)), events: hidden.map((b) => b.ev) })
    } else {
      for (const b of cluster) shown.push({ ...b, cols: ends.length })
    }
    cluster = []
    ends = []
  }
  for (const b of dayBoxes()) {
    if (b.top >= clusterEnd) close()
    let col = ends.findIndex((end) => end <= b.top)
    if (col < 0) col = ends.length
    ends[col] = b.top + b.h
    b.col = col
    cluster.push(b)
    clusterEnd = Math.max(clusterEnd, b.top + b.h)
  }
  close()
  return { blocks: shown, chips }
})
const blocks = computed(() => layout.value.blocks)
const chips = computed(() => layout.value.chips)
const list = shallowRef<More | null>(null)
watch(chips, (cs) => { if (list.value && !cs.some((c) => c.top === list.value!.top)) list.value = null })

function blockStyle(b: { top: number, h: number, col: number, cols: number }) {
  return {
    top: `${b.top}px`,
    height: `${b.h}px`,
    insetInlineStart: `calc(var(--calday-gutter) + (100% - var(--calday-gutter)) * ${b.col} / ${b.cols})`,
    width: `calc((100% - var(--calday-gutter)) / ${b.cols} - 2px)`,
  }
}

/* ---- the now line ---- */
const now = ref(Date.now())
let clock: ReturnType<typeof setInterval> | undefined
const nowY = computed(() => (now.value >= dayStart.value && now.value < dayEnd.value ? yOf(now.value) : null))

/* ---- opened at the now line, else the first event (else 08:00) ---- */
const rootEl = ref<HTMLElement | null>(null)
const gridEl = ref<HTMLElement | null>(null)
let touched = false
function scroller(): HTMLElement | null {
  let el = rootEl.value?.parentElement || null
  while (el && !/(auto|scroll)/.test(getComputedStyle(el).overflowY)) el = el.parentElement
  return el
}
function scrollToStart() {
  const sc = scroller()
  const grid = gridEl.value
  if (!sc || !grid || touched) return
  const target = nowY.value ?? blocks.value[0]?.top ?? Math.min(8, hours.value.length - 1) * HOUR_PX
  const offset = grid.getBoundingClientRect().top - sc.getBoundingClientRect().top + sc.scrollTop
  sc.scrollTop = Math.max(0, offset + target - HOUR_PX)
}
watch(() => props.day, () => {
  touched = false
  void nextTick(scrollToStart)
})
watch(() => props.items, () => { void nextTick(scrollToStart) })

/* ---- tap on empty time: the add sheet on that hour (S2-2) ---- */
let down: { x: number, y: number, t: number, touch: boolean } | null = null
let tapOk = false
function onGridDown(e: PointerEvent) {
  touched = true
  list.value = null
  down = { x: e.clientX, y: e.clientY, t: e.timeStamp, touch: e.pointerType !== 'mouse' }
  tapOk = false
}
function onGridUp(e: PointerEvent) {
  const d = down
  down = null
  tapOk = Boolean(d && (!d.touch || calSwipeIsTap([d, { x: e.clientX, y: e.clientY, t: e.timeStamp }])))
}
function onHourClick(e: MouseEvent, i: number) {
  /* a keyboard press has no pointer; a pointer must have been a tap */
  const ok = e.detail === 0 || tapOk
  tapOk = false
  if (!ok || dragClick(e)) return
  const row = hours.value[i]
  if (!row) return
  const preset = calPhoneHourPreset(props.day, Number(row.label.slice(0, 2)))
  if (preset) emit('create', { ...preset, at: isoAt(row.at), endAt: isoAt(row.at + HOUR_MS) })
}

/* ---- 097 hold-to-drag on an event: time only, the day stays ---- */
type Gesture = { ev: CalendarItem, pointerId: number, touch: boolean, x0: number, y0: number, t0: number, grab: number, live: boolean, timer: ReturnType<typeof setTimeout> | undefined }
let gesture: Gesture | null = null
const lifted = ref('')
const saving = ref('')
const notice = ref('')
let noticeTimer: ReturnType<typeof setTimeout> | undefined
let upStamp = Number.NEGATIVE_INFINITY
const dragClick = (e: Event) => e.timeStamp - upStamp < 100

function gridY(clientY: number) {
  return clientY - (gridEl.value?.getBoundingClientRect().top || 0)
}

function onEvDown(e: PointerEvent, ev: CalendarItem, top: number) {
  touched = true
  list.value = null
  if (e.button !== 0 || gesture || saving.value || !calEditable(ev)) return
  gesture = {
    ev, pointerId: e.pointerId, touch: e.pointerType !== 'mouse', x0: e.clientX, y0: e.clientY, t0: e.timeStamp,
    grab: gridY(e.clientY) - top, live: false, timer: undefined,
  }
  window.addEventListener('pointermove', onMove)
  window.addEventListener('pointerup', onUp)
  window.addEventListener('pointercancel', onCancel)
  if (gesture.touch) gesture.timer = setTimeout(liftOff, CAL_SWIPE_HOLD_MS + 1)
}

function liftOff() {
  const g = gesture
  if (!g || g.live) return
  g.live = true
  lifted.value = g.ev.id
}

function onMove(e: PointerEvent) {
  const g = gesture
  if (!g || e.pointerId !== g.pointerId) return
  if (!g.live) {
    const far = Math.hypot(e.clientX - g.x0, e.clientY - g.y0)
    if (g.touch && far >= CAL_SWIPE_TAP_PX) return stop() /* a scroll or a page turn */
    if (g.touch && e.timeStamp - g.t0 > CAL_SWIPE_HOLD_MS) liftOff()
    else if (!g.touch && far > CAL_DRAG_PX) liftOff()
    if (!g.live) return
  }
  e.preventDefault()
  const y = Math.min(gridH.value - 1, Math.max(0, gridY(e.clientY) - g.grab))
  const min = calMinuteOf(isoAt(atOf(y)))
  if (Number.isNaN(min)) return
  const next = calMoveTo(g.ev, props.day, calSnap(min, 0, CAL_DAY_MIN - CAL_SNAP_MIN))
  if (next) preview.value = { id: g.ev.id, ...next }
  edgeScroll(e.clientY)
}

function edgeScroll(y: number) {
  const sc = scroller()
  if (!sc) return
  const r = sc.getBoundingClientRect()
  if (y < r.top + 32) sc.scrollTop -= 12
  else if (y > r.bottom - 32) sc.scrollTop += 12
}

function stop() {
  const g = gesture
  if (g?.timer) clearTimeout(g.timer)
  gesture = null
  lifted.value = ''
  window.removeEventListener('pointermove', onMove)
  window.removeEventListener('pointerup', onUp)
  window.removeEventListener('pointercancel', onCancel)
}
function onCancel(e: PointerEvent) {
  if (!gesture || e.pointerId !== gesture.pointerId) return
  stop()
  preview.value = null
}
function onUp(e: PointerEvent) {
  const g = gesture
  if (!g || e.pointerId !== g.pointerId) return
  const live = g.live
  stop()
  if (!live) return
  upStamp = e.timeStamp
  const next = preview.value
  if (!next || calSameTimes(g.ev, next)) {
    preview.value = null
    return
  }
  void saveTimes(g.ev, next)
}

/* a lifted event keeps the finger: no scroll, and no page turn in the shell */
function onTouchMove(e: TouchEvent) {
  if (!gesture?.live) return
  if (e.cancelable) e.preventDefault()
  e.stopPropagation()
}
function onContextMenu(e: Event) {
  if (gesture) e.preventDefault()
}

function onEvClick(e: Event, ev: CalendarItem) {
  if (dragClick(e)) return
  emit('peek', ev)
}

function say(key: string) {
  notice.value = key
  if (noticeTimer) clearTimeout(noticeTimer)
  noticeTimer = setTimeout(() => { notice.value = '' }, 6000)
}

/* PATCH the new times under If-Match (the updated_at this view read); the
   shell reads the day again on CALENDAR_CHANGED_EVENT */
async function saveTimes(ev: CalendarItem, next: Times) {
  saving.value = ev.id
  try {
    await withSessionRetry(api, () => calendarUpdate(api, ev.id, { starts_at: next.starts_at, ends_at: next.ends_at }, props.today, ev.updated_at))
    window.dispatchEvent(new Event(CALENDAR_CHANGED_EVENT))
  } catch (e) {
    preview.value = null
    const key = calDragErrorKey((e || {}) as { status?: number, token?: string })
    if (key === 'calendar_event.drag_conflict') window.dispatchEvent(new Event(CALENDAR_CHANGED_EVENT))
    say(key)
  } finally {
    saving.value = ''
  }
}
/* the read-back carries the saved times: the preview has done its work */
watch(() => props.items, () => {
  if (!saving.value && !gesture) preview.value = null
})

onMounted(() => {
  clock = setInterval(() => { now.value = Date.now() }, 60000)
  rootEl.value?.addEventListener('touchmove', onTouchMove, { passive: false })
  void nextTick(scrollToStart)
})
onBeforeUnmount(() => {
  stop()
  if (clock) clearInterval(clock)
  if (noticeTimer) clearTimeout(noticeTimer)
  rootEl.value?.removeEventListener('touchmove', onTouchMove)
})
</script>

<style scoped>
/* spec 107 v1.2 T011: the Working hours line */
.calday__worked { margin-block: 4px 8px; }
.calday {
  --calday-gutter: 3rem;
  position: relative;
  min-width: 0;
}

/* ---- the all-day row: two lines at most, then +n ---- */
.calday__allday {
  display: flex;
  align-items: flex-start;
  gap: 6px;
  min-width: 0;
  padding-bottom: 8px;
  margin-bottom: 4px;
  border-bottom: 1px solid var(--color-border);
}
.calday__allday-label {
  flex: 0 0 auto;
  width: calc(var(--calday-gutter) - 6px);
  padding-top: 12px;
  font-size: 0.75rem;
  color: var(--color-muted);
  overflow-wrap: anywhere;
}
.calday__allday-list {
  display: flex;
  flex-direction: column;
  gap: 4px;
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
  padding: 0;
  list-style: none;
}
.calday__chip,
.calday__list-row {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  min-height: var(--tap);
  padding: 0 10px;
  box-sizing: border-box;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  background: var(--color-surface);
  color: var(--color-fg);
  box-shadow: var(--bevel-shine), var(--bevel-shade);
  font: inherit;
  font-size: 0.875rem;
  text-align: start;
  cursor: pointer;
}
.calday__chip-title,
.calday__ev-title {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.calday__allday-more,
.calday__more {
  display: inline-grid;
  place-items: center;
  min-width: var(--tap);
  min-height: var(--tap);
  padding: 0 8px;
  box-sizing: border-box;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-md);
  background: var(--color-selected);
  color: var(--color-heading);
  box-shadow: var(--focus-3d), var(--bevel-shine), var(--bevel-shade);
  font: inherit;
  font-size: 0.875rem;
  font-weight: 600;
  cursor: pointer;
}
.calday__allday-more { flex: 0 0 auto; align-self: flex-end; }

/* ---- the time grid: 48 px an hour ---- */
.calday__grid {
  position: relative;
  min-width: 0;
  touch-action: pan-y;
}
.calday__hour {
  position: absolute;
  inset-inline: 0;
  height: 48px;
  display: block;
  padding: 0;
  box-sizing: border-box;
  border: 0;
  background: transparent;
  color: var(--color-muted);
  font: inherit;
  text-align: start;
  cursor: pointer;
}
.calday__hour-label {
  position: absolute;
  inset-inline-start: 0;
  top: 2px;
  width: calc(var(--calday-gutter) - 6px);
  font-size: 0.75rem;
  font-variant-numeric: tabular-nums;
}
/* the hour line straight across, clear of the button's rounded corners */
.calday__hour::before {
  content: '';
  position: absolute;
  inset-inline: 0;
  top: 0;
  border-top: 1px solid var(--color-border);
}
.calday__hour:active { background: var(--color-selected); }

.calday__now {
  position: absolute;
  inset-inline: calc(var(--calday-gutter) - 6px) 0;
  z-index: 3;
  height: 0;
  border-top: 2px solid var(--color-danger);
  pointer-events: none;
}

.calday__ev {
  position: absolute;
  z-index: 2;
  display: flex;
  flex-direction: column;
  align-items: stretch;
  justify-content: flex-start;
  min-width: var(--tap);
  padding: 3px 6px 3px 18px;
  box-sizing: border-box;
  overflow: hidden;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  color: var(--color-fg);
  box-shadow: var(--bevel-shine), var(--bevel-shade);
  font: inherit;
  font-size: 0.8125rem;
  line-height: 1.25;
  text-align: start;
  cursor: pointer;
  touch-action: pan-y;
  -webkit-touch-callout: none;
  user-select: none;
}
.calday__ev--short { justify-content: center; padding-block: 0; }
.calday__ev--cont { border-bottom-style: dashed; }
.calday__ev--lifted {
  z-index: 4;
  border-color: var(--color-accent);
  box-shadow: var(--focus-3d), var(--bevel-shine), var(--bevel-shade);
}
.calday__ev--saving { opacity: 0.7; }
.calday__ev-time {
  font-size: 0.75rem;
  color: var(--color-muted);
  font-variant-numeric: tabular-nums;
}
.calday__ev .calday__dot {
  position: absolute;
  inset-inline-start: 6px;
  top: 8px;
}
.calday__ev--short .calday__dot { top: calc(50% - 4px); }

/* an event colour as a dot: its ring keeps it >= 3:1 on light themes (S4-8) */
.calday__dot {
  flex: 0 0 auto;
  width: 8px;
  height: 8px;
  border-radius: var(--radius-pill);
  background: var(--cal-ev-color, var(--color-accent));
  box-shadow: var(--cal-dot-ring);
}

.calday__more { position: absolute; z-index: 2; }
.calday__list {
  position: absolute;
  inset-inline: var(--calday-gutter) 0;
  z-index: 5;
  display: flex;
  flex-direction: column;
  gap: 4px;
  padding: 6px;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-md);
  background: var(--color-bg-2);
  box-shadow: var(--focus-3d);
}

.calday__notice {
  position: sticky;
  bottom: 0;
  z-index: 6;
  margin: 8px 0 0;
  padding: 6px 10px;
  border: 1px solid var(--color-warn);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  font-size: 0.875rem;
}

.calday button:focus-visible {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}
</style>
