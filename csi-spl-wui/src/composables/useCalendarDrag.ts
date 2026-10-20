/**
 * 097 T013: drag on the calendar's week (CalendarMainView, r14-05). A hold
 * (touch) or a move (mouse) lifts an event to move it, its handle resizes it,
 * and on an empty grid it draws a new event's slot. The event stays where it
 * is while `preview` (a ghost) shows where it lands; the release hands the
 * new times to `onDrop`, a drawn slot to `onCreate`.
 */
import type { Ref, ShallowRef } from 'vue'
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { calEditable } from '~/utils/calendar-event-form.mjs'
import {
  CAL_DAY_MIN, CAL_DRAG_PX, CAL_HOLD_MS, CAL_SNAP_MIN, CAL_TOUCH_SLOP_PX,
  calCreateSlot, calMinuteOf, calMoveTo, calResizeTo, calSameTimes, calSnap,
} from '~/utils/calendar-drag.mjs'
import type { CalTimes } from '~/utils/calendar-drag.mjs'

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

export type CalendarDragOptions = {
  /** the week's scroller: it scrolls on near its edges and holds the touch guard */
  weekEl: Ref<HTMLElement | null>
  /** where the dragged event would land; the view draws it and clears it */
  preview: ShallowRef<({ id: string } & CalTimes) | null>
  /** a save is running: no new gesture starts */
  busy: () => boolean
  onCreate: (day: string, span: { start: string, end: string }) => void
  onDrop: (ev: CalendarItem, next: CalTimes) => void
}

/* one view's drag: the gesture under way and what the view draws of it */
type Drag = {
  o: CalendarDragOptions
  gesture: Gesture | null
  dragging: Ref<boolean>
  lifted: Ref<string>
  ghost: Ref<{ day: string, a: number, b: number } | null>
  /* the click a drag's release makes is not a click on the day or the event */
  upStamp: number
  move: (e: PointerEvent) => void
  up: (e: PointerEvent) => void
  cancel: (e: PointerEvent) => void
}

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

function begin(s: Drag, e: PointerEvent, kind: Gesture['kind'], ev: CalendarItem | null, day: string) {
  if (e.button !== 0 || s.gesture || s.o.busy()) return
  const hit = hitAt(e.clientX, e.clientY)
  const min = hit?.min ?? null
  const g: Gesture = {
    kind, ev, day, pointerId: e.pointerId, touch: e.pointerType !== 'mouse',
    x0: e.clientX, y0: e.clientY, t0: e.timeStamp, live: false, timer: undefined,
    grab: ev && min !== null && !ev.all_day ? min - calMinuteOf(ev.starts_at) : 0,
    from: min === null ? 0 : Math.floor(min / CAL_SNAP_MIN) * CAL_SNAP_MIN,
  }
  s.gesture = g
  window.addEventListener('pointermove', s.move)
  window.addEventListener('pointerup', s.up)
  window.addEventListener('pointercancel', s.cancel)
  /* a resize handle is its own target: it drags at once, finger or mouse */
  if (kind === 'resize') liftOff(s)
  else if (g.touch) g.timer = setTimeout(() => liftOff(s), CAL_HOLD_MS)
}

/* the hold is over (or the mouse moved): the drag begins */
function liftOff(s: Drag) {
  const g = s.gesture
  if (!g || g.live) return
  g.live = true
  s.dragging.value = true
  if (g.ev) s.lifted.value = g.ev.id
  if (g.kind === 'create') s.ghost.value = { day: g.day, a: g.from, b: g.from + 60 }
}

function onMove(s: Drag, e: PointerEvent) {
  const g = s.gesture
  if (!g || e.pointerId !== g.pointerId) return
  if (!g.live) {
    const far = Math.hypot(e.clientX - g.x0, e.clientY - g.y0)
    /* a hold is judged by the input's own clock: a busy page may run the
       timer after the finger has already held long enough and moved */
    if (g.touch && e.timeStamp - g.t0 >= CAL_HOLD_MS) liftOff(s)
    else if (g.touch && far > CAL_TOUCH_SLOP_PX) stop(s) /* a swipe: the list scrolls */
    else if (!g.touch && far > CAL_DRAG_PX) liftOff(s)
    if (!g.live) return
  }
  e.preventDefault()
  follow(s, g, e.clientX, e.clientY)
  edgeScroll(s.o.weekEl.value, e.clientY)
}

function follow(s: Drag, g: Gesture, x: number, y: number) {
  const hit = hitAt(x, y)
  if (!hit) return
  if (g.kind === 'create') {
    if (hit.day === g.day && hit.min !== null) s.ghost.value = { day: g.day, a: g.from, b: calSnap(hit.min) }
    return
  }
  const ev = g.ev!
  let next: CalTimes | null = null
  if (g.kind === 'resize') {
    if (hit.day === g.day && hit.min !== null) next = calResizeTo(ev, calSnap(hit.min))
  } else {
    next = calMoveTo(ev, hit.day, hit.min === null || ev.all_day ? null : calSnap(hit.min - g.grab, 0, CAL_DAY_MIN - CAL_SNAP_MIN))
  }
  if (next) s.o.preview.value = { id: ev.id, ...next }
}

/* near the scroller's top or bottom edge the view scrolls on */
function edgeScroll(box: HTMLElement | null, y: number) {
  if (!box) return
  const r = box.getBoundingClientRect()
  if (y < r.top + 32) box.scrollTop -= 12
  else if (y > r.bottom - 32) box.scrollTop += 12
}

function stop(s: Drag) {
  const g = s.gesture
  if (g?.timer) clearTimeout(g.timer)
  s.gesture = null
  s.dragging.value = false
  s.lifted.value = ''
  window.removeEventListener('pointermove', s.move)
  window.removeEventListener('pointerup', s.up)
  window.removeEventListener('pointercancel', s.cancel)
}
function onCancel(s: Drag, e: PointerEvent) {
  if (!s.gesture || e.pointerId !== s.gesture.pointerId) return
  stop(s)
  s.o.preview.value = null
  s.ghost.value = null
}
function onUp(s: Drag, e: PointerEvent) {
  const g = s.gesture
  if (!g || e.pointerId !== g.pointerId) return
  const live = g.live
  stop(s)
  if (!live) return
  s.upStamp = e.timeStamp
  if (g.kind === 'create') {
    const gh = s.ghost.value
    s.ghost.value = null
    if (gh) s.o.onCreate(g.day, calCreateSlot(gh.a, gh.b))
    return
  }
  const next = s.o.preview.value
  if (!next || calSameTimes(g.ev!, next)) {
    s.o.preview.value = null
    return
  }
  s.o.onDrop(g.ev!, next)
}

export function useCalendarDrag(o: CalendarDragOptions) {
  const s: Drag = {
    o, gesture: null, dragging: ref(false), lifted: ref(''), ghost: ref<Drag['ghost']['value']>(null), upStamp: Number.NEGATIVE_INFINITY,
    move: (e) => onMove(s, e), up: (e) => onUp(s, e), cancel: (e) => onCancel(s, e),
  }
  /* a live drag keeps the finger from scrolling. The listener is on the
     scroller for good: the browser decides at touchstart whether a touch may
     be cancelled, so one added at pointerdown is too late (every touchmove
     then arrives uncancelable and the day scrolls under the drag) */
  const onTouchMove = (e: TouchEvent) => { if (s.gesture?.live && e.cancelable) e.preventDefault() }
  onMounted(() => o.weekEl.value?.addEventListener('touchmove', onTouchMove, { passive: false }))
  onBeforeUnmount(() => o.weekEl.value?.removeEventListener('touchmove', onTouchMove))
  onBeforeUnmount(() => stop(s))
  return {
    dragging: s.dragging,
    lifted: s.lifted,
    ghost: s.ghost,
    /** a pointer is down on the week (held, or already dragging) */
    active: () => s.gesture !== null,
    dragClick: (e: Event) => e.timeStamp - s.upStamp < 100,
    onItemDown(e: PointerEvent, ev: CalendarItem, day: string) {
      e.stopPropagation()
      if (calEditable(ev)) begin(s, e, 'move', ev, day)
    },
    onResizeDown(e: PointerEvent, ev: CalendarItem, day: string) {
      if (!calEditable(ev)) return
      e.preventDefault()
      begin(s, e, 'resize', ev, day)
    },
    onGridDown: (e: PointerEvent, day: string) => begin(s, e, 'create', null, day),
    onContextMenu(e: Event) {
      if (s.gesture) e.preventDefault()
    },
  }
}
