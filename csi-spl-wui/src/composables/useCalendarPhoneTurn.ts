/*
 * CalendarPhone's page turn (r17-02, spec 4.3, H2, H6): a sideways swipe
 * or < / > turns one period, the neighbour page tilting in; a swipe from
 * the Back edge stays the mobile stack's Back.
 */
import type { ComputedRef, Ref } from 'vue'
import type { useMobileStack } from '~/composables/useMobileStack'
import { calPhoneRange, calPhoneStep } from '~/utils/calendar-phone-nav.mjs'
import { calSwipeClaims, calSwipeClassify, calSwipeInEdge, calSwipeLock } from '~/utils/calendar-swipe.mjs'

type View = 'month' | 'week' | 'day'
type Point = { x: number, y: number, t: number }

type TurnOpts = {
  view: Ref<View>
  shownDay: Ref<string>
  period: ComputedRef<string>
  title: ComputedRef<string>
  titleOf: (day: string) => string
  viewEl: Ref<HTMLElement | null>
  trackEl: Ref<HTMLElement | null>
  stack: Pick<ReturnType<typeof useMobileStack>, 'swipe'>
  onMove: (target: string) => void
}
/* the state the touch track and the motion share: the refs, the finger's
   offset and the pending paint frame */
type TurnState = TurnOpts & {
  side: Ref<0 | 1 | -1>
  turning: Ref<boolean>
  moving: Ref<boolean>
  m: { dx: number, raf: number }
}

const isRtl = () => document.documentElement.dir === 'rtl'
const reducedMotion = () => window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true
const flat = (x: number) => `perspective(1200px) translateX(${x}px) rotateY(0deg) scale(1)`

/* the motion: rest, snap back, turn one period */
function turnMotion(c: TurnState) {
  const { view, shownDay, viewEl, trackEl, side, turning, moving, m, onMove } = c
  function rest() {
    cancelAnimationFrame(m.raf)
    m.raf = 0
    m.dx = 0
    moving.value = false
    if (trackEl.value) trackEl.value.style.transform = ''
  }

  async function snapBack(from: number) {
    const el = trackEl.value
    if (el && !reducedMotion() && typeof el.animate === 'function') {
      /* a cancelled animation (unmount, a new touch) still rests the page below */
      await el.animate([{ transform: flat(from) }, { transform: flat(0) }], { duration: 150, easing: 'ease-out' }).finished.catch(() => undefined)
    }
    rest()
    side.value = 0
  }

  /** turn one period: a swipe's release (from its offset) or < / > (from 0) */
  async function turn(dir: 1 | -1, from = 0) {
    if (turning.value) return
    const target = calPhoneStep(view.value, shownDay.value, dir)
    if (!target) return
    side.value = dir
    turning.value = true
    moving.value = true
    await nextTick()
    const el = trackEl.value
    const w = viewEl.value?.clientWidth || window.innerWidth
    const s = isRtl() ? -1 : 1
    const to = -dir * s * w
    if (el && !reducedMotion() && typeof el.animate === 'function') {
      cancelAnimationFrame(m.raf)
      m.raf = 0
      el.style.transform = ''
      const tilt = `perspective(1200px) translateX(${(from + to) / 2}px) rotateY(${dir * s * 8}deg) scale(0.98)`
      /* a cancelled animation still lands the turn below */
      await el.animate(
        [{ transform: flat(from) }, { transform: tilt, offset: 0.5 }, { transform: flat(to) }],
        { duration: 220, easing: 'ease-out' },
      ).finished.catch(() => undefined)
    }
    shownDay.value = target
    rest()
    side.value = 0
    turning.value = false
    onMove(target)
  }
  return { snapBack, turn }
}

/* the finger: the track follows it, its release turns or snaps back */
function turnTouch(c: TurnState, snapBack: (from: number) => Promise<void>, turn: (dir: 1 | -1, from?: number) => Promise<void>) {
  const { trackEl, side, turning, moving, m, stack } = c
  let pts: Point[] = []
  let lock: 'none' | 'x' | 'y' = 'none'
  function paint() {
    m.raf = 0
    if (trackEl.value) trackEl.value.style.transform = `translateX(${m.dx}px)`
  }

  function onTouchStart(e: TouchEvent) {
    const p = e.touches[0]
    pts = !turning.value && e.touches.length === 1 && p ? [{ x: p.clientX, y: p.clientY, t: e.timeStamp }] : []
    lock = 'none'
    m.dx = 0
  }
  function onTouchMove(e: TouchEvent) {
    const p = e.touches[0]
    const p0 = pts[0]
    if (!p || !p0) return
    const pt = { x: p.clientX, y: p.clientY, t: e.timeStamp }
    pts.push(pt)
    lock = calSwipeLock(p0, pt, lock)
    if (lock !== 'x') return
    const d = pt.x - p0.x
    const rtl = isRtl()
    /* a track toward Back from the edge zone is the stack's Back, not a turn */
    if ((rtl ? d < 0 : d > 0) && calSwipeInEdge(p0.x, window.innerWidth, rtl)) return
    m.dx = d
    side.value = (rtl ? d > 0 : d < 0) ? 1 : -1
    moving.value = true
    if (!m.raf) m.raf = requestAnimationFrame(paint)
  }
  function onTouchEnd() {
    const p0 = pts[0]
    const rtl = isRtl()
    /* the view keeps its swipes; one from the Back edge stays the stack's */
    if (p0 && calSwipeClaims(p0.x, window.innerWidth, rtl)) stack.swipe.claim()
    const kind = p0 ? calSwipeClassify({ points: pts, width: window.innerWidth, rtl }) : 'none'
    const from = m.dx
    pts = []
    if (kind === 'next' || kind === 'prev') void turn(kind === 'next' ? 1 : -1, from)
    else if (moving.value) void snapBack(from)
  }
  function onTouchCancel() {
    const from = m.dx
    pts = []
    if (moving.value) void snapBack(from)
  }
  return { onTouchStart, onTouchMove, onTouchEnd, onTouchCancel }
}

export function useCalendarPhoneTurn(opts: TurnOpts) {
  const { view, shownDay, period, title, titleOf } = opts
  /** the neighbour on screen: 1 = the next period, -1 = the previous, 0 = none */
  const side = ref<0 | 1 | -1>(0)
  const turning = ref(false)
  const moving = ref(false)

  const pages = computed(() => {
    const cur = { key: `p:${period.value}`, day: shownDay.value, dir: 0, period: period.value, title: title.value, inert: turning.value }
    if (side.value === 0) return [cur]
    const day = calPhoneStep(view.value, shownDay.value, side.value)
    const r = calPhoneRange(view.value, day)
    return [cur, { key: `n:${day}`, day, dir: side.value, period: r?.from || '', title: titleOf(day), inert: !turning.value }]
  })

  const c: TurnState = { ...opts, side, turning, moving, m: { dx: 0, raf: 0 } }
  const { snapBack, turn } = turnMotion(c)
  onBeforeUnmount(() => cancelAnimationFrame(c.m.raf))
  return { turning, moving, pages, isRtl, turn, ...turnTouch(c, snapBack, turn) }
}
