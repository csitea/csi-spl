/*
 * r17-09: CalendarPhoneDay's 097 hold-to-drag on an event, moved out of
 * CalendarPhoneDay.vue. Time only, the day stays; saved with If-Match.
 *
 * The day, today and the items are getters so a changed prop is read on the
 * next call. `touched` stays a plain let in the view (its grid handlers read
 * it): onTouch sets it. The view's mount hooks call onTouchMove and dispose.
 */
import type { Ref, ShallowRef } from 'vue'
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import type { useSpoolApi } from '~/composables/useSpoolApi'
import { calEditable } from '~/utils/calendar-event-form.mjs'
import { calendarUpdate } from '~/utils/calendar-events-api.mjs'
import { CALENDAR_CHANGED_EVENT } from '~/utils/calendar-reminders.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { CAL_DAY_MIN, CAL_DRAG_PX, CAL_SNAP_MIN, calDragErrorKey, calMinuteOf, calMoveTo, calSameTimes, calSnap } from '~/utils/calendar-drag.mjs'
import { CAL_SWIPE_HOLD_MS, CAL_SWIPE_TAP_PX } from '~/utils/calendar-swipe.mjs'

type Times = { starts_at: string, ends_at: string }
type Gesture = { ev: CalendarItem, pointerId: number, touch: boolean, x0: number, y0: number, t0: number, grab: number, live: boolean, timer: ReturnType<typeof setTimeout> | undefined }

type DayDragOpts = {
  api: ReturnType<typeof useSpoolApi>
  day: () => string
  today: () => string
  items: () => CalendarItem[]
  peek: (ev: CalendarItem) => void
  preview: ShallowRef<({ id: string } & Times) | null>
  list: ShallowRef<unknown>
  gridEl: Ref<HTMLElement | null>
  gridH: Readonly<Ref<number>>
  atOf: (y: number) => number
  isoAt: (ms: number) => string
  scroller: () => HTMLElement | null
  onTouch: () => void
}
/* the state the pointer handlers and the save share: the refs, the gesture
   in flight, the notice timer and the last lift's pointerup stamp */
type DragState = DayDragOpts & {
  lifted: Ref<string>
  saving: Ref<string>
  notice: Ref<string>
  m: { gesture: Gesture | null, noticeTimer: ReturnType<typeof setTimeout> | undefined, upStamp: number }
}

function gridY(c: DragState, clientY: number) {
  return clientY - (c.gridEl.value?.getBoundingClientRect().top || 0)
}

function edgeScroll(c: DragState, y: number) {
  const sc = c.scroller()
  if (!sc) return
  const r = sc.getBoundingClientRect()
  if (y < r.top + 32) sc.scrollTop -= 12
  else if (y > r.bottom - 32) sc.scrollTop += 12
}

/* the notice and the PATCH */
function dragSave(c: DragState) {
  const { api, preview, saving, notice, m } = c
  function say(key: string) {
    notice.value = key
    if (m.noticeTimer) clearTimeout(m.noticeTimer)
    m.noticeTimer = setTimeout(() => { notice.value = '' }, 6000)
  }

  /* PATCH the new times under If-Match (the updated_at this view read); the
     shell reads the day again on CALENDAR_CHANGED_EVENT */
  async function saveTimes(ev: CalendarItem, next: Times) {
    saving.value = ev.id
    try {
      await withSessionRetry(api, () => calendarUpdate(api, ev.id, { starts_at: next.starts_at, ends_at: next.ends_at }, c.today(), ev.updated_at))
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
  return saveTimes
}

/* the gesture: press, lift, move, release */
function dragGesture(c: DragState, saveTimes: (ev: CalendarItem, next: Times) => Promise<void>) {
  const { preview, list, gridH, atOf, isoAt, lifted, saving, m } = c
  function onEvDown(e: PointerEvent, ev: CalendarItem, top: number) {
    c.onTouch()
    list.value = null
    if (e.button !== 0 || m.gesture || saving.value || !calEditable(ev)) return
    m.gesture = {
      ev, pointerId: e.pointerId, touch: e.pointerType !== 'mouse', x0: e.clientX, y0: e.clientY, t0: e.timeStamp,
      grab: gridY(c, e.clientY) - top, live: false, timer: undefined,
    }
    window.addEventListener('pointermove', onMove)
    window.addEventListener('pointerup', onUp)
    window.addEventListener('pointercancel', onCancel)
    if (m.gesture.touch) m.gesture.timer = setTimeout(liftOff, CAL_SWIPE_HOLD_MS + 1)
  }

  function liftOff() {
    const g = m.gesture
    if (!g || g.live) return
    g.live = true
    lifted.value = g.ev.id
  }

  function onMove(e: PointerEvent) {
    const g = m.gesture
    if (!g || e.pointerId !== g.pointerId) return
    if (!g.live) {
      const far = Math.hypot(e.clientX - g.x0, e.clientY - g.y0)
      if (g.touch && far >= CAL_SWIPE_TAP_PX) return stop() /* a scroll or a page turn */
      if (g.touch && e.timeStamp - g.t0 > CAL_SWIPE_HOLD_MS) liftOff()
      else if (!g.touch && far > CAL_DRAG_PX) liftOff()
      if (!g.live) return
    }
    e.preventDefault()
    const y = Math.min(gridH.value - 1, Math.max(0, gridY(c, e.clientY) - g.grab))
    const min = calMinuteOf(isoAt(atOf(y)))
    if (Number.isNaN(min)) return
    const next = calMoveTo(g.ev, c.day(), calSnap(min, 0, CAL_DAY_MIN - CAL_SNAP_MIN))
    if (next) preview.value = { id: g.ev.id, ...next }
    edgeScroll(c, e.clientY)
  }

  function stop() {
    const g = m.gesture
    if (g?.timer) clearTimeout(g.timer)
    m.gesture = null
    lifted.value = ''
    window.removeEventListener('pointermove', onMove)
    window.removeEventListener('pointerup', onUp)
    window.removeEventListener('pointercancel', onCancel)
  }
  function onCancel(e: PointerEvent) {
    if (!m.gesture || e.pointerId !== m.gesture.pointerId) return
    stop()
    preview.value = null
  }
  function onUp(e: PointerEvent) {
    const g = m.gesture
    if (!g || e.pointerId !== g.pointerId) return
    const live = g.live
    stop()
    if (!live) return
    m.upStamp = e.timeStamp
    const next = preview.value
    if (!next || calSameTimes(g.ev, next)) {
      preview.value = null
      return
    }
    void saveTimes(g.ev, next)
  }
  return { onEvDown, stop }
}

export function useCalendarPhoneDayDrag(opts: DayDragOpts) {
  const c: DragState = {
    ...opts,
    lifted: ref(''),
    saving: ref(''),
    notice: ref(''),
    m: { gesture: null, noticeTimer: undefined, upStamp: Number.NEGATIVE_INFINITY },
  }
  const { m } = c
  const { onEvDown, stop } = dragGesture(c, dragSave(c))
  const dragClick = (e: Event) => e.timeStamp - m.upStamp < 100

  /* a lifted event keeps the finger: no scroll, and no page turn in the shell */
  function onTouchMove(e: TouchEvent) {
    if (!m.gesture?.live) return
    if (e.cancelable) e.preventDefault()
    e.stopPropagation()
  }
  function onContextMenu(e: Event) {
    if (m.gesture) e.preventDefault()
  }

  function onEvClick(e: Event, ev: CalendarItem) {
    if (dragClick(e)) return
    opts.peek(ev)
  }

  /* the read-back carries the saved times: the preview has done its work */
  watch(opts.items, () => {
    if (!c.saving.value && !m.gesture) c.preview.value = null
  })

  /* the view's unmount: drop a gesture in flight and the notice timer */
  function dispose() {
    stop()
    if (m.noticeTimer) clearTimeout(m.noticeTimer)
  }

  return { lifted: c.lifted, saving: c.saving, notice: c.notice, dragClick, onEvDown, onEvClick, onTouchMove, onContextMenu, dispose }
}
