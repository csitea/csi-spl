<!-- spec 089 T007: the Calendar's main view, a PLACEHOLDER. T008 replaces this
     file with the library grid (Day / Week / Month, drag to move, the event
     dialog). Until then it shows the week holding `focus` - seven day columns
     with the items of GET /v1/calendar/events (spec 6.1.2) - and Today /
     previous / next, so the year strip has something to move (AC-04).
     Loaded as its own chunk by pages/calendar.vue (defineAsyncComponent).
     T009, phone (`phone`, <= 820 px, spec 2.2): opens on the Day view - the
     shown day only, previous / next step a day - and Week is the seven days
     as a list, one under another. Today / previous / next and Day | Week sit
     in a bar at the bottom, above the composer dock, where a thumb reaches.
     097 T013 (G1, spec 5.1.1): the desktop week and the Day view are a time
     grid - all-day items on top, timed ones placed by their clock - where an
     event drags to another time or day, its bottom edge drags to resize, and
     a drag on empty time opens a new event for that span. The phone Week list
     moves an event between days. A finger holds 250 ms first (a swipe still
     scrolls); a held event shows its 44 px resize handle. Every save is a
     PATCH with If-Match; edit_conflict takes the other change and says so.
     097 T017 (G13, spec 4.8 / 5.1.4): a delete shows "Event deleted · Undo"
     for 10 s (the shared UndoSnackbar); Undo restores it with the same id. On
     a phone it floats 8 px above the bottom bar, full width less 8 px margins,
     so Today / previous / next stay usable. The calendar menu (the ... button)
     opens the trash: CalendarTrash, its own lazy chunk. -->
<template>
  <section
    class="cal-main"
    :class="{ 'cal-main--phone': phone, 'cal-main--dragging': dragging }"
    data-test="calendar-main"
    :data-week="weekStart"
    :data-day="focus"
    :data-view="view"
    :data-state="state"
  >
    <div ref="barEl" class="cal-main__bar">
      <button type="button" class="btn cal-main__new" data-test="calendar-new" @click="openCreate(focus)"><UiIcon name="plus" :size="16" />{{ t('calendar_event.new') }}</button>
      <button type="button" class="btn ghost" data-test="calendar-today" @click="emit('move', today)">{{ t('calendar.today') }}</button>
      <button type="button" class="icon-btn" data-test="calendar-prev" :aria-label="prevLabel" :title="prevLabel" @click="step(-1)">
        <UiIcon name="chevron-left" :size="18" />
      </button>
      <button type="button" class="icon-btn" data-test="calendar-next" :aria-label="nextLabel" :title="nextLabel" @click="step(1)">
        <UiIcon name="chevron-right" :size="18" />
      </button>
      <h3 class="cal-main__range" data-test="calendar-range" aria-live="polite">{{ range }}</h3>
      <button
        type="button"
        class="icon-btn cal-main__menu"
        data-test="calendar-menu"
        :aria-label="t('calendar_trash.menu')"
        :title="t('calendar_trash.menu')"
        aria-haspopup="menu"
        :aria-expanded="menu ? 'true' : 'false'"
        @click="openMenu"
      >
        <UiIcon name="more" :size="18" />
      </button>
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
    <p v-if="notice" class="cal-main__notice" role="status" data-test="calendar-notice" :data-key="notice">{{ t(notice) }}</p>
    <div ref="weekEl" class="cal-week" :class="{ 'cal-week--grid': grid }" :style="{ '--cal-days': shown.length }" data-test="calendar-week">
      <div v-if="grid" class="cal-week__gutter" aria-hidden="true">
        <div class="cal-week__top" />
        <div class="cal-grid cal-grid--gutter">
          <span v-for="h in HOURS" :key="h" class="cal-grid__label" :style="{ top: pct(h * 60) }" dir="ltr">{{ calHhmm(h * 60) }}</span>
        </div>
      </div>
      <div
        v-for="day in shown"
        :key="day"
        class="cal-week__day"
        :class="{ 'cal-week__day--today': day === today }"
        data-test="calendar-week-day"
        :data-day="day"
        @click="onDayClick($event, day)"
      >
        <div class="cal-week__top">
          <h4 class="cal-week__head">{{ dayHead(day) }}</h4>
          <ul class="cal-week__list">
            <li
              v-for="ev in (grid ? allDayOf(day) : byDay.get(day) || [])"
              :key="ev.id"
              v-bind="itemAttrs(ev)"
              @pointerdown="onItemDown($event, ev, day)"
              @click.stop="onItemClick($event, ev)"
              @keydown.enter.prevent.stop="openPeek(ev)"
              @contextmenu="onContextMenu"
            >
              <span v-if="!ev.all_day" class="cal-week__time" dir="ltr">{{ isoClock(ev.starts_at) }}</span>
              <span class="cal-week__title">{{ ev.title }}</span>
              <span v-if="ev.release_version" class="cal-week__badge" dir="ltr">{{ ev.release_version }}</span>
              <span v-if="ev.audience === 'private'" class="cal-week__badge" data-test="calendar-item-private">{{ t('calendar_event.private_badge') }}</span>
            </li>
            <li v-if="dropped && dropDay === day && dropDay !== calEventDay(liftedEv!) && (dropped.all_day || !grid)" class="cal-week__item cal-week__item--ghost" data-test="calendar-drag-ghost" aria-hidden="true">
              <span v-if="!dropped.all_day" class="cal-week__time" dir="ltr">{{ isoClock(dropped.starts_at) }}</span>
              <span class="cal-week__title">{{ dropped.title }}</span>
            </li>
          </ul>
        </div>
        <div
          v-if="grid"
          class="cal-grid"
          data-test="calendar-grid"
          :data-grid-day="day"
          @pointerdown="onGridDown($event, day)"
          @contextmenu="onContextMenu"
        >
          <div
            v-for="b in timedOf(day)"
            :key="b.ev.id"
            v-bind="itemAttrs(b.ev)"
            :style="boxStyle(b)"
            @pointerdown="onItemDown($event, b.ev, day)"
            @click.stop="onItemClick($event, b.ev)"
            @keydown.enter.prevent.stop="openPeek(b.ev)"
          >
            <span class="cal-ev__body">
              <span class="cal-week__time" dir="ltr">{{ isoClock(b.ev.starts_at) }}</span>
              <span class="cal-week__title">{{ b.ev.title }}</span>
              <span v-if="b.ev.release_version" class="cal-week__badge" dir="ltr">{{ b.ev.release_version }}</span>
              <span v-if="b.ev.audience === 'private'" class="cal-week__badge" data-test="calendar-item-private">{{ t('calendar_event.private_badge') }}</span>
            </span>
            <span
              v-if="resizable(b.ev)"
              class="cal-ev__resize"
              data-test="calendar-item-resize"
              aria-hidden="true"
              @pointerdown.stop="onResizeDown($event, b.ev, day)"
              @click.stop
            />
          </div>
          <div
            v-if="dropBox && dropDay === day"
            class="cal-week__item cal-ev cal-week__item--ghost"
            data-test="calendar-drag-ghost"
            aria-hidden="true"
            :style="boxStyle({ ...dropBox, col: 0, cols: 1 })"
          >
            <span class="cal-ev__body">
              <span class="cal-week__time" dir="ltr">{{ isoClock(dropBox.ev.starts_at) }}–{{ isoClock(dropBox.ev.ends_at) }}</span>
              <span class="cal-week__title">{{ dropBox.ev.title }}</span>
            </span>
          </div>
          <div
            v-if="ghost && ghost.day === day"
            class="cal-grid__ghost"
            data-test="calendar-create-ghost"
            :style="{ top: pct(Math.min(ghost.a, ghost.b)), height: pct(Math.max(CAL_SNAP_MIN, Math.abs(ghost.b - ghost.a))) }"
          />
        </div>
      </div>
    </div>
    <CalendarEventDialog v-model:open="dialogOpen" :event="dialogEvent" :copy="dialogCopy" :day="dialogDay" :today="today" :span="dialogSpan" @saved="reload" @deleted="onDeleted" />
    <CalendarEventPopover v-model:open="peekOpen" :event="peekEvent" @edit="openEdit" @duplicate="openDuplicate" />
    <UiPointMenu
      :open="menu !== null"
      :x="menu?.x || 0"
      :y="menu?.y || 0"
      :items="MENU_ITEMS"
      :label="t('calendar_trash.menu')"
      block="cal-menu"
      testid="calendar-menu-panel"
      @choose="onMenu"
      @close="menu = null"
    />
    <LazyCalendarTrash v-if="trashMounted" v-model:open="trashOpen" :today="today" @restored="reload" />
    <UndoSnackbar
      v-if="undoEv"
      :key="undoEv.id"
      class="cal-undo"
      :style="{ '--cal-bottom-bar-h': undoLift }"
      testid="calendar-undo"
      :data-id="undoEv.id"
      icon="trash"
      :text="t('calendar_trash.deleted')"
      :undo-label="t('calendar_trash.undo')"
      :close-label="t('common.close')"
      :busy="undoBusy"
      :duration="CAL_UNDO_MS"
      @undo="undoDelete"
      @dismiss="undoEv = null"
    />
  </section>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { calAddDays, calWeekday, calWeekDays, calWeekStart } from '~/utils/calendar-year.mjs'
import { isoClock } from '~/utils/date-iso.mjs'
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { hubJsonHeaders } from '~/utils/hub-headers'
import { CAL_COLORS, calEditable } from '~/utils/calendar-event-form.mjs'
import { calendarRestore, calendarUpdate } from '~/utils/calendar-events-api.mjs'
import type { PointMenuItem } from '~/components/UiPointMenu.vue'
import { CALENDAR_CHANGED_EVENT } from '~/utils/calendar-reminders.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import {
  CAL_DAY_MIN, CAL_DRAG_PX, CAL_HOLD_MS, CAL_SNAP_MIN, CAL_TOUCH_SLOP_PX,
  calCreateSlot, calDayLayout, calDragErrorKey, calEventDay, calHhmm, calMinuteOf, calMoveTo, calResizeTo, calSameTimes, calSnap,
} from '~/utils/calendar-drag.mjs'
import type { CalTimes } from '~/utils/calendar-drag.mjs'

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
/* 097 T013: a time grid everywhere but the phone's Week list */
const grid = computed(() => !props.phone || view.value === 'day')
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
/* the event being dragged stays where it is (a touch keeps its target
   node, or the finger's events go nowhere) and a ghost shows where it lands */
const preview = shallowRef<({ id: string } & CalTimes) | null>(null)
const dropped = computed(() => {
  const p = preview.value
  const ev = p && items.value.find((x) => x.id === p.id)
  return ev ? { ...ev, starts_at: p.starts_at, ends_at: p.ends_at } : null
})
/* in a list the ghost shows only on another day: on its own day it would
   push the days below away from the finger */
const liftedEv = computed(() => (preview.value ? items.value.find((x) => x.id === preview.value!.id) || null : null))
const dropDay = computed(() => (dropped.value ? calEventDay(dropped.value) : ''))
const dropBox = computed(() => (dropped.value && !dropped.value.all_day && grid.value ? calDayLayout([dropped.value])[0] || null : null))
/* each item on the day it starts: an all-day item (an official day) on its
   UTC day, a timed one on the viewer's day, the zone its clock prints in */
const byDay = computed(() => {
  const out = new Map<string, CalendarItem[]>()
  for (const ev of items.value) {
    const day = calEventDay(ev)
    out.set(day, [...(out.get(day) || []), ev])
  }
  return out
})
const layouts = computed(() => {
  const out = new Map<string, ReturnType<typeof calDayLayout<CalendarItem>>>()
  for (const [day, list] of byDay.value) out.set(day, calDayLayout(list.filter((ev) => !ev.all_day)))
  return out
})
const allDayOf = (day: string) => (byDay.value.get(day) || []).filter((ev) => ev.all_day)
const timedOf = (day: string) => layouts.value.get(day) || []

const HOURS = Array.from({ length: 23 }, (_, i) => i + 1)
const pct = (min: number) => `${(min / CAL_DAY_MIN) * 100}%`
function boxStyle(b: { top: number, len: number, col: number, cols: number }) {
  return {
    top: pct(b.top),
    height: pct(b.len),
    insetInlineStart: `${(b.col / b.cols) * 100}%`,
    width: `calc(${100 / b.cols}% - 2px)`,
  }
}

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

/* 097 T013: a grid opens scrolled to the morning, or to the first event
   shown when it starts earlier */
const weekEl = ref<HTMLElement | null>(null)
let scrolledFor = ''
watch([state, grid, () => shown.value.join()], async () => {
  const key = `${grid.value}:${shown.value.join()}`
  if (state.value !== 'ready' || !grid.value || scrolledFor === key) return
  scrolledFor = key
  await nextTick()
  const box = weekEl.value
  const g = box?.querySelector<HTMLElement>('.cal-grid[data-grid-day]')
  if (!box || !g) return
  const firsts = shown.value.flatMap((d) => timedOf(d).map((b) => b.top))
  const min = Math.max(0, Math.min(8 * 60, ...firsts) - 30)
  const r = g.getBoundingClientRect()
  const gridTop = r.top - box.getBoundingClientRect().top + box.scrollTop
  const head = (g.previousElementSibling as HTMLElement | null)?.offsetHeight || 0
  box.scrollTop = gridTop + (min / CAL_DAY_MIN) * r.height - head
})

/* 089 T008 v1 (owner msg 72db6282): New event, or a click on a day, opens
   CalendarEventDialog for a new event on that day; a click on a stored
   event opens it to edit or delete. An issue deadline and an official day
   are not edited here. /calendar?event=<id> (a reminder's Open, T006) opens
   that event once it is in the shown week.
   097 T014 (G11): a click shows the event's pop-over first; its Edit opens
   the dialog, its Duplicate a new event filled from it. */
const route = useRoute()
const dialogOpen = ref(false)
const dialogEvent = shallowRef<CalendarItem | null>(null)
const dialogDay = ref(props.focus)
const dialogSpan = ref<{ start: string, end: string } | null>(null)
const dialogCopy = shallowRef<CalendarItem | null>(null)
const peekOpen = ref(false)
const peekEvent = shallowRef<CalendarItem | null>(null)
function openCreate(day: string, span: { start: string, end: string } | null = null) {
  dialogEvent.value = null
  dialogCopy.value = null
  dialogDay.value = day
  dialogSpan.value = span
  dialogOpen.value = true
}
function openEdit(ev: CalendarItem) {
  if (!calEditable(ev)) return
  peekOpen.value = false
  dialogEvent.value = ev
  dialogCopy.value = null
  dialogDay.value = String(ev.starts_at || '').slice(0, 10)
  dialogSpan.value = null
  dialogOpen.value = true
}
function openPeek(ev: CalendarItem) {
  if (!calEditable(ev)) return
  peekEvent.value = ev
  peekOpen.value = true
}
function openDuplicate(ev: CalendarItem) {
  peekOpen.value = false
  dialogEvent.value = null
  dialogCopy.value = ev
  dialogDay.value = String(ev.starts_at || '').slice(0, 10)
  dialogSpan.value = null
  dialogOpen.value = true
}
function reload() {
  void load()
}

/* ---- 097 T017: Undo after a delete, the menu, the trash ------------------ */

const CAL_UNDO_MS = 10000
const undoEv = shallowRef<CalendarItem | null>(null)
const undoBusy = ref(false)
/* a phone: the bottom bar's height over the composer dock, so the toast
   floats 8 px above it (spec M4: bar + dock + 8 px) */
const undoLift = ref('48px')
const barEl = ref<HTMLElement | null>(null)
function measureBar() {
  const bar = barEl.value
  if (!props.phone || !bar) return
  undoLift.value = `calc(${Math.max(0, Math.round(window.innerHeight - bar.getBoundingClientRect().top))}px - var(--composer-dock-h, 0px))`
}
function onDeleted(ev: CalendarItem) {
  reload()
  measureBar()
  undoEv.value = ev
}
async function undoDelete() {
  const ev = undoEv.value
  if (!ev || undoBusy.value) return
  undoBusy.value = true
  try {
    await withSessionRetry(api, () => calendarRestore(api, ev.id, props.today))
    window.dispatchEvent(new Event(CALENDAR_CHANGED_EVENT))
    reload()
  } catch {
    say('calendar_trash.restore_failed')
  } finally {
    undoBusy.value = false
    undoEv.value = null
  }
}
onMounted(() => window.addEventListener('resize', measureBar))
onBeforeUnmount(() => window.removeEventListener('resize', measureBar))

const MENU_ITEMS: PointMenuItem[] = [{ id: 'trash', icon: 'trash', labelKey: 'calendar_trash.title' }]
const menu = ref<{ x: number, y: number } | null>(null)
function openMenu(e: MouseEvent) {
  const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
  menu.value = menu.value ? null : { x: r.left, y: r.bottom }
}
const trashOpen = ref(false)
const trashMounted = ref(false)
function onMenu(id: string) {
  menu.value = null
  if (id !== 'trash') return
  trashMounted.value = true
  trashOpen.value = true
}
let askedEvent = ''
watch([items, () => route.query.event], () => {
  const id = String(route.query.event || '')
  if (!id || id === askedEvent) return
  const ev = items.value.find((x) => x.id === id)
  if (!ev) return
  askedEvent = id
  openEdit(ev)
})

/* ---- 097 T013: drag ---------------------------------------------------- */

type Gesture = {
  kind: 'move' | 'resize' | 'create'
  ev: CalendarItem | null
  day: string
  pointerId: number
  touch: boolean
  x0: number
  y0: number
  t0: number
  live: boolean
  timer: ReturnType<typeof setTimeout> | undefined
  grab: number
  from: number
}
let gesture: Gesture | null = null
const dragging = ref(false)
const lifted = ref('')
/* a phone: the event a hold picked, the one showing its resize handle */
const picked = ref('')
const ghost = ref<{ day: string, a: number, b: number } | null>(null)
const saving = ref('')
const notice = ref('')
let noticeTimer: ReturnType<typeof setTimeout> | undefined
/* the click a drag's release makes is not a click on the day or the event */
let upStamp = Number.NEGATIVE_INFINITY
const dragClick = (e: Event) => e.timeStamp - upStamp < 100

function itemAttrs(ev: CalendarItem) {
  const edit = calEditable(ev)
  return {
    class: ['cal-week__item', {
      'cal-ev': !ev.all_day && grid.value,
      'cal-week__item--edit': edit,
      'cal-week__item--lifted': lifted.value === ev.id,
      'cal-week__item--left': preview.value?.id === ev.id,
      'cal-week__item--picked': picked.value === ev.id,
      'cal-week__item--saving': saving.value === ev.id,
    }],
    'data-test': 'calendar-item',
    'data-id': ev.id,
    'data-source': ev.source,
    'data-kind': ev.kind,
    'data-audience': ev.audience,
    'data-starts': ev.starts_at,
    'data-ends': ev.ends_at,
    'data-color': ev.color || undefined,
    role: edit ? 'button' : undefined,
    tabindex: edit ? 0 : undefined,
    /* 097 T014 (G8): the event's colour, one of the palette's theme variables */
    style: ev.color && CAL_COLORS.includes(ev.color) ? { '--cal-ev-color': `var(--cal-color-${ev.color})` } : undefined,
  }
}
/* the desktop always offers the bottom edge; a phone only on the held event */
const resizable = (ev: CalendarItem) => calEditable(ev) && !ev.all_day && (!props.phone || picked.value === ev.id)

/* under the pointer: a grid's day and minute, or a list day (minute null) */
function hitAt(x: number, y: number): { day: string, min: number | null } | null {
  for (const el of document.elementsFromPoint(x, y)) {
    const g = el.closest<HTMLElement>('[data-grid-day]')
    if (g) {
      const r = g.getBoundingClientRect()
      return { day: String(g.dataset.gridDay), min: ((y - r.top) / r.height) * CAL_DAY_MIN }
    }
    const d = el.closest<HTMLElement>('[data-test=calendar-week-day]')
    if (d) return { day: String(d.dataset.day), min: null }
  }
  return null
}

function begin(e: PointerEvent, kind: Gesture['kind'], ev: CalendarItem | null, day: string) {
  if (e.button !== 0 || gesture || saving.value) return
  const hit = hitAt(e.clientX, e.clientY)
  const min = hit?.min ?? null
  gesture = {
    kind, ev, day, pointerId: e.pointerId, touch: e.pointerType !== 'mouse',
    x0: e.clientX, y0: e.clientY, t0: e.timeStamp, live: false, timer: undefined,
    grab: ev && min !== null && !ev.all_day ? min - calMinuteOf(ev.starts_at) : 0,
    from: min === null ? 0 : Math.floor(min / CAL_SNAP_MIN) * CAL_SNAP_MIN,
  }
  window.addEventListener('pointermove', onMove)
  window.addEventListener('pointerup', onUp)
  window.addEventListener('pointercancel', onCancel)
  /* a resize handle is its own target: it drags at once, finger or mouse */
  if (kind === 'resize') liftOff()
  else if (gesture.touch) gesture.timer = setTimeout(liftOff, CAL_HOLD_MS)
}

function onItemDown(e: PointerEvent, ev: CalendarItem, day: string) {
  e.stopPropagation()
  if (calEditable(ev)) begin(e, 'move', ev, day)
}
function onResizeDown(e: PointerEvent, ev: CalendarItem, day: string) {
  if (!calEditable(ev)) return
  e.preventDefault()
  begin(e, 'resize', ev, day)
}
function onGridDown(e: PointerEvent, day: string) {
  picked.value = ''
  begin(e, 'create', null, day)
}

/* the hold is over (or the mouse moved): the drag begins */
function liftOff() {
  const g = gesture
  if (!g || g.live) return
  g.live = true
  dragging.value = true
  if (g.ev) {
    lifted.value = g.ev.id
    if (g.touch) picked.value = g.ev.id
  }
  if (g.kind === 'create') ghost.value = { day: g.day, a: g.from, b: g.from + 60 }
}

function onMove(e: PointerEvent) {
  const g = gesture
  if (!g || e.pointerId !== g.pointerId) return
  if (!g.live) {
    const far = Math.hypot(e.clientX - g.x0, e.clientY - g.y0)
    /* a hold is judged by the input's own clock: a busy page may run the
       timer after the finger has already held long enough and moved */
    if (g.touch && e.timeStamp - g.t0 >= CAL_HOLD_MS) liftOff()
    else if (g.touch && far > CAL_TOUCH_SLOP_PX) stop() /* a swipe: the list scrolls */
    else if (!g.touch && far > CAL_DRAG_PX) liftOff()
    if (!g.live) return
  }
  e.preventDefault()
  follow(g, e.clientX, e.clientY)
  edgeScroll(e.clientY)
}

function follow(g: Gesture, x: number, y: number) {
  const hit = hitAt(x, y)
  if (!hit) return
  if (g.kind === 'create') {
    if (hit.day === g.day && hit.min !== null) ghost.value = { day: g.day, a: g.from, b: calSnap(hit.min) }
    return
  }
  const ev = g.ev!
  let next: CalTimes | null = null
  if (g.kind === 'resize') {
    if (hit.day === g.day && hit.min !== null) next = calResizeTo(ev, calSnap(hit.min))
  } else {
    next = calMoveTo(ev, hit.day, hit.min === null || ev.all_day ? null : calSnap(hit.min - g.grab, 0, CAL_DAY_MIN - CAL_SNAP_MIN))
  }
  if (next) preview.value = { id: ev.id, ...next }
}

/* near the scroller's top or bottom edge the view scrolls on */
function edgeScroll(y: number) {
  const box = weekEl.value
  if (!box) return
  const r = box.getBoundingClientRect()
  if (y < r.top + 32) box.scrollTop -= 12
  else if (y > r.bottom - 32) box.scrollTop += 12
}

/* a live drag keeps the finger from scrolling. The listener is on the
   scroller for good: the browser decides at touchstart whether a touch may
   be cancelled, so one added at pointerdown is too late (every touchmove
   then arrives uncancelable and the day scrolls under the drag) */
function onTouchMove(e: TouchEvent) {
  if (gesture?.live && e.cancelable) e.preventDefault()
}
onMounted(() => weekEl.value?.addEventListener('touchmove', onTouchMove, { passive: false }))
onBeforeUnmount(() => weekEl.value?.removeEventListener('touchmove', onTouchMove))
function onContextMenu(e: Event) {
  if (gesture) e.preventDefault()
}

function stop() {
  const g = gesture
  if (g?.timer) clearTimeout(g.timer)
  gesture = null
  dragging.value = false
  lifted.value = ''
  window.removeEventListener('pointermove', onMove)
  window.removeEventListener('pointerup', onUp)
  window.removeEventListener('pointercancel', onCancel)
}
function onCancel(e: PointerEvent) {
  if (!gesture || e.pointerId !== gesture.pointerId) return
  stop()
  preview.value = null
  ghost.value = null
}
function onUp(e: PointerEvent) {
  const g = gesture
  if (!g || e.pointerId !== g.pointerId) return
  const live = g.live
  stop()
  if (!live) return
  upStamp = e.timeStamp
  if (g.kind === 'create') {
    const gh = ghost.value
    ghost.value = null
    if (gh) openCreate(g.day, calCreateSlot(gh.a, gh.b))
    return
  }
  const next = preview.value
  if (!next || calSameTimes(g.ev!, next)) {
    preview.value = null
    return
  }
  void saveTimes(g.ev!, next)
}
onBeforeUnmount(() => {
  stop()
  if (noticeTimer) clearTimeout(noticeTimer)
})

function onItemClick(e: Event, ev: CalendarItem) {
  if (dragClick(e)) return
  picked.value = ''
  openPeek(ev)
}
function onDayClick(e: Event, day: string) {
  if (dragClick(e)) return
  openCreate(day)
}

function say(key: string) {
  notice.value = key
  if (noticeTimer) clearTimeout(noticeTimer)
  noticeTimer = setTimeout(() => { notice.value = '' }, 6000)
}
function replaceItem(ev: CalendarItem) {
  items.value = items.value.map((x) => (x.id === ev.id ? ev : x))
}

/* PATCH the new times under If-Match: the updated_at this view read. A
   stale one is 409 edit_conflict: the other change stays, shown at once from
   the answer's event, and the week is read again. */
async function saveTimes(ev: CalendarItem, next: CalTimes) {
  saving.value = ev.id
  try {
    const out = await withSessionRetry(api, () => calendarUpdate(api, ev.id, { starts_at: next.starts_at, ends_at: next.ends_at }, props.today, ev.updated_at))
    replaceItem(out)
    window.dispatchEvent(new Event(CALENDAR_CHANGED_EVENT))
  } catch (e) {
    const err = (e || {}) as { status?: number, token?: string, event?: CalendarItem | null }
    const key = calDragErrorKey(err)
    if (key === 'calendar_event.drag_conflict') {
      if (err.event) replaceItem(err.event)
      void load()
    }
    say(key)
  } finally {
    preview.value = null
    saving.value = ''
  }
}
</script>

<style scoped>
.cal-main { display: flex; flex-direction: column; gap: 8px; padding: 8px 12px; min-width: 0; height: 100%; min-height: 0; }
.cal-main__bar { display: flex; align-items: center; gap: 6px; }
.cal-main__range { margin: 0 0 0 8px; font-size: 1rem; font-weight: 600; }
.cal-main__notice {
  margin: 0;
  padding: 6px 10px;
  border: 1px solid var(--color-warn);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  font-size: 0.875rem;
  overflow-wrap: anywhere;
}
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
.cal-week__item[data-color]:not(.cal-ev) { box-shadow: inset 3px 0 0 var(--cal-ev-color); }
.cal-week__item--edit { cursor: pointer; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }
.cal-week__item--edit:hover { background: var(--color-bg-2); }
.cal-week__item--edit:focus-visible { outline: 2px solid var(--color-accent); outline-offset: 1px; }
.cal-main__new { display: inline-flex; align-items: center; gap: 4px; }
.cal-week__time { color: var(--color-muted); }
.cal-week__badge { font-size: 0.6875rem; padding: 0 4px; border: 1px solid var(--color-border); border-radius: var(--radius-sm); }

/* 097 T013: the time grid - a gutter of hours, then each day: its head and
   all-day items on one row (as tall as the tallest), its 24 hours below */
.cal-week--grid {
  --cal-hour: 48px;
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  overscroll-behavior: contain;
  grid-template-columns: 3rem repeat(var(--cal-days), minmax(0, 1fr));
  grid-template-rows: auto auto;
}
.cal-week--grid .cal-week__day,
.cal-week__gutter {
  grid-row: 1 / span 2;
  display: grid;
  grid-template-rows: subgrid;
  padding: 0;
}
.cal-week--grid .cal-week__day:first-child { border-inline-start: 1px solid var(--color-border); }
.cal-week--grid .cal-week__top {
  position: sticky;
  top: 0;
  z-index: 3;
  padding: 4px 6px;
  background: var(--color-bg);
  border-bottom: 1px solid var(--color-border);
}
.cal-grid {
  position: relative;
  height: calc(24 * var(--cal-hour));
  background-image: repeating-linear-gradient(to bottom, var(--color-border) 0 1px, transparent 1px var(--cal-hour));
  touch-action: pan-y;
}
.cal-grid--gutter { background-image: none; }
.cal-grid__label {
  position: absolute;
  inset-inline-end: 4px;
  transform: translateY(-50%);
  font-size: 0.6875rem;
  color: var(--color-muted);
}
.cal-ev {
  position: absolute;
  z-index: 1;
  display: block;
  padding: 0;
  overflow: visible;
  border-inline-start: 3px solid var(--cal-ev-color, var(--color-accent));
  box-sizing: border-box;
}
.cal-ev__body {
  display: flex; flex-wrap: wrap; gap: 0 4px; align-items: baseline;
  height: 100%;
  padding: 1px 4px;
  overflow: hidden;
}
.cal-ev__resize {
  position: absolute;
  inset-inline: 0;
  bottom: 0;
  height: 6px;
  cursor: ns-resize;
  touch-action: none;
}
.cal-week__item--lifted {
  z-index: 4;
  outline: 2px solid var(--color-accent);
  box-shadow: 0 6px 16px rgb(0 0 0 / 25%);
  background: var(--color-surface-hover);
}
.cal-week__item--left.cal-week__item--edit { opacity: 0.45; box-shadow: none; }
.cal-week__item--saving { opacity: 0.7; }
.cal-week__item--ghost {
  z-index: 4;
  pointer-events: none;
  outline: 2px solid var(--color-accent);
  box-shadow: 0 6px 16px rgb(0 0 0 / 25%);
  background: var(--color-surface-hover);
}
.cal-grid__ghost {
  position: absolute;
  inset-inline: 2px;
  z-index: 2;
  border: 2px dashed var(--color-accent);
  border-radius: var(--radius-sm);
  background: var(--color-selected);
  pointer-events: none;
}
.cal-main--dragging { cursor: grabbing; -webkit-user-select: none; user-select: none; }

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
.cal-main--phone .cal-week--grid { grid-template-columns: 3rem minmax(0, 1fr); }
.cal-main--phone .cal-main__notice { order: 0; margin: 8px 8px 0; }
.cal-main--phone .cal-week__day {
  padding: 8px 10px;
  border-inline-start: 0;
  border-top: 1px solid var(--color-border);
}
.cal-main--phone .cal-week__day:first-child { border-top: 0; }
.cal-main--phone .cal-week--grid .cal-week__day { padding: 0; border-top: 0; border-inline-start: 1px solid var(--color-border); }
.cal-main--phone .cal-week__head { font-size: 0.9375rem; }
.cal-main--phone .cal-week__item { font-size: 0.9375rem; padding: 8px 10px; }
.cal-main--phone .cal-ev { padding: 0; }
.cal-main--phone .cal-week__badge { font-size: 0.8125rem; }
/* 097 5.1.1: on a held event, a pill on its bottom edge in a 44 x 44 hit area */
.cal-main--phone .cal-ev__resize {
  inset-inline: auto;
  left: 50%;
  bottom: calc(var(--tap) / -2);
  width: var(--tap);
  height: var(--tap);
  transform: translateX(-50%);
  z-index: 5;
}
.cal-main--phone .cal-ev__resize::after {
  content: '';
  position: absolute;
  left: 50%;
  top: 50%;
  width: 28px;
  height: 6px;
  transform: translate(-50%, -50%);
  border-radius: var(--radius-pill);
  background: var(--color-accent);
}
.cal-main--phone .cal-week__item--picked { z-index: 4; outline: 2px solid var(--color-accent); }
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
/* 097 T017 (spec 5.1.4, M4): on a phone the Undo toast floats 8 px above the
   bottom bar and the composer dock, full width less 8 px margins (the shared
   snackbar's own phone place is the top) */
.cal-main--phone .cal-undo {
  top: auto;
  bottom: calc(var(--cal-bottom-bar-h, 48px) + var(--composer-dock-h, 0px) + 8px);
  left: 8px;
  right: 8px;
  width: auto;
  max-width: none;
  transform: none;
}
.cal-main--phone .cal-main__menu { min-height: var(--tap); min-width: var(--tap); }
</style>
