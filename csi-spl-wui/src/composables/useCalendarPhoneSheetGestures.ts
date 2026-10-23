/*
 * r18-02: CalendarPhoneSheet's gestures and keys, moved out of
 * CalendarPhoneSheet.vue: the keyboard lift, the drag-down to close
 * (9.4 #4), Escape and the Tab trap.
 *
 * `cancel` stays in the view (save and Cancel share its emit). The view's
 * opened() / closed() add and remove onWindowKey and onViewport, and its
 * reset() writes dy = 0.
 */
import type { Ref } from 'vue'

type SheetGesturesOpts = {
  sheetEl: Ref<HTMLElement | null>
  bodyEl: Ref<HTMLElement | null>
  busy: Ref<boolean>
  cancel: () => void
}

/* keyboard safety: a keyboard that overlays the page (the visual viewport
   shrinks, the layout one does not) lifts the sheet above it */
function sheetLift() {
  const lift = ref(0)
  function onViewport() {
    const vv = window.visualViewport
    lift.value = vv ? Math.max(0, Math.round(window.innerHeight - vv.height - vv.offsetTop)) : 0
  }
  return { lift, onViewport }
}

/* drag-down to close (9.4 #4) */
function sheetDrag(c: SheetGesturesOpts, lift: Ref<number>) {
  const { sheetEl, bodyEl, busy, cancel } = c
  const dy = ref(0)
  const dragging = ref(false)
  let y0 = 0
  let x0 = 0
  let armed = false
  let lock: '' | 'x' | 'y' = ''
  const sheetStyle = computed(() => {
    const s: Record<string, string> = {}
    if (lift.value) {
      /* the lifted sheet fits above the keyboard: a full-height one (Edit)
         lifted whole slid its header and title off the top (t1 650cec31) */
      const room = `calc(100% - ${lift.value}px - env(safe-area-inset-top, 0px))`
      s.bottom = `${lift.value}px`
      s.maxHeight = room
      s.minHeight = `min(50%, ${room})`
    }
    if (dy.value > 0) s.transform = `translateY(${dy.value}px)`
    return s
  })
  function dragStart(e: TouchEvent, fromHead: boolean) {
    const p = e.touches[0]
    if (!p || e.touches.length !== 1 || busy.value) {
      armed = false
      return
    }
    armed = fromHead || (bodyEl.value?.scrollTop || 0) <= 0
    y0 = p.clientY
    x0 = p.clientX
    lock = ''
  }
  function dragMove(e: TouchEvent) {
    const p = e.touches[0]
    if (!armed || !p) return
    const d = p.clientY - y0
    if (!lock) {
      if (Math.abs(p.clientX - x0) >= 10) lock = 'x'
      else if (Math.abs(d) >= 10) lock = d > 0 ? 'y' : 'x'
      if (lock === 'x') armed = false
      if (lock !== 'y') return
    }
    if (e.cancelable) e.preventDefault()
    dragging.value = true
    dy.value = Math.max(0, d)
  }
  function dragEnd() {
    const was = dy.value
    armed = false
    lock = ''
    if (!dragging.value) return
    dragging.value = false
    const h = sheetEl.value?.offsetHeight || 0
    dy.value = 0
    if (was > Math.min(160, Math.max(80, h * 0.25))) cancel()
  }
  return { dy, dragging, sheetStyle, dragStart, dragMove, dragEnd }
}

/* Escape, and Tab kept inside the sheet */
function sheetKeys(c: SheetGesturesOpts) {
  const { sheetEl, cancel } = c
  function onWindowKey(e: KeyboardEvent) {
    if (e.key !== 'Escape' || e.defaultPrevented || e.isComposing) return
    e.preventDefault()
    cancel()
  }
  function onKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault()
      e.stopPropagation()
      cancel()
      return
    }
    if (e.key !== 'Tab' || !sheetEl.value) return
    const sel = 'button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])'
    const items = [...sheetEl.value.querySelectorAll<HTMLElement>(sel)].filter((el) => el.offsetParent !== null)
    const first = items[0]
    const last = items[items.length - 1]
    if (!first || !last) return
    const active = document.activeElement as HTMLElement | null
    if (!e.shiftKey && (active === last || !sheetEl.value.contains(active))) {
      e.preventDefault()
      first.focus()
    } else if (e.shiftKey && (active === first || !sheetEl.value.contains(active))) {
      e.preventDefault()
      last.focus()
    }
  }
  return { onWindowKey, onKeydown }
}

export function useCalendarPhoneSheetGestures(opts: SheetGesturesOpts) {
  const { lift, onViewport } = sheetLift()
  return { onViewport, ...sheetDrag(opts, lift), ...sheetKeys(opts) }
}
