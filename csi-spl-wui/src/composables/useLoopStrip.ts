import { nextTick, onBeforeUnmount, onMounted, ref, watch, type Ref } from 'vue'
import { loopPosition } from '~/utils/section-strip.mjs'

/**
 * CLE-77886 (owner, t1 topic ac0fa400, msg 8ebbce0e): the phone's section
 * strip "rolls constantly ... like a continuous strip". While its controls
 * overflow the row, `on` is true and the strip renders a copy of them on
 * each side ([data-loop] boxes, aria-hidden, after the real controls in the
 * DOM, the "before" one moved first by CSS `order`). A scroll that drifts
 * into either copy jumps one copy width back - the same picture - so a swipe
 * never meets an end. Never on desktop (`enabled` false): nothing is cloned.
 *
 * `selected` is a selector for the current control. The first centre is read
 * in the ResizeObserver callback, after the browser's own layout, so the read
 * is not a forced layout. The copies land on the following frame, so while
 * the strip is enabled the row stays hidden until that centred scroll is
 * written. The first painted frame is already centred.
 *
 * Phone profile, n=5 interleaved, 390x844 device pixel ratio 3, CPU 4x,
 * load 19..11, base ea62caba. useLoopStrip self-time ratio 0.22 on / and
 * 0.23 on /issues. LayoutDuration 84 -> 68 ms on / and 75 -> 74 ms on
 * /issues. The first visible frame has both copies and is centred (n=5).
 */

const REAL = ':scope > .sidebar-rail__tabs > .sidebar-tab, :scope > .sidebar-rail__help, :scope > .sidebar-rail__docs, :scope > .sidebar-rail__qto, :scope > .sidebar-rail__settings'

type Snap = {
  span: number
  gap: number
  rtl: boolean
  max: number
  pos: number
  delta: number
  fully: boolean
  set: number
  scrollLeft: number
  hasItems: boolean
  hasSel: boolean
  view: number
}

type MountSnap = { span: number, gap: number, rtl: boolean, max: number, delta: number, scrollLeft: number }
type WriteSnap = { rtl: boolean, max: number, pos: number, delta: number, set: number, force: boolean, fully: boolean, hasSel: boolean }
type WrapFn = (pos: number, set: number) => number

type LoopOpts = { enabled: () => boolean, selected: string, watchKey: () => unknown }
type LoopCtx = {
  el: Ref<HTMLElement | null>
  opts: LoopOpts
  on: Ref<boolean>
  centred: { v: boolean }
  quiet: { v: boolean }
}

/** do the real controls overflow the row (their span, without the copies) */
export function stripOverflows(span: number, view: number) {
  return span > view + 1
}

/**
 * scrollLeft once the two copies exist, predicted from a read taken before
 * they were inserted. One copy is the real span plus the row's gap (the
 * before-copy, `order: -1`, shifts the row by that). The same picture as
 * reveal + wrap, with no geometry read after the copies land.
 */
export function loopMountScroll(snap: MountSnap, wrap: WrapFn) {
  const set = snap.span + snap.gap
  const postDelta = snap.rtl ? snap.delta - set : snap.delta + set
  const maxAfter = snap.max + set * 2
  const scrolled = snap.scrollLeft + postDelta
  const pos = snap.rtl ? scrolled + maxAfter : scrolled
  const next = wrap(pos, set)
  return snap.rtl ? next - maxAfter : next
}

/** scrollLeft from a read taken while the row is already in its final shape */
export function loopScrollWrite(snap: WriteSnap, wrap: WrapFn) {
  if (!snap.hasSel || (!snap.force && snap.fully)) return null
  const pos = snap.pos + snap.delta
  const next = snap.set > 0 ? wrap(pos, snap.set) : pos
  return snap.rtl ? next - snap.max : next
}

function realItems(box: HTMLElement | null) {
  return [...(box?.querySelectorAll<HTMLElement>(REAL) || [])]
}

function spanOf(rects: DOMRect[]) {
  let min = Infinity
  let max = -Infinity
  for (const r of rects) {
    if (r.left < min) min = r.left
    if (r.right > max) max = r.right
  }
  return max - min
}

function readSnap(box: HTMLElement, selected: string): Snap {
  const items = realItems(box)
  const rects = items.map((i) => i.getBoundingClientRect())
  const cs = getComputedStyle(box)
  const rtl = cs.direction === 'rtl'
  const gap = Number.parseFloat(cs.columnGap)
  const max = box.scrollWidth - box.clientWidth
  const scrollLeft = box.scrollLeft
  const b = box.getBoundingClientRect()
  const sel = box.querySelector<HTMLElement>(selected)
  const r = sel?.getBoundingClientRect()
  const first = items[0]
  const twin = box.querySelector<HTMLElement>('[data-loop="after"] > *')
  return {
    span: rects.length ? spanOf(rects) : 0,
    gap: Number.isFinite(gap) ? gap : 0,
    rtl,
    max,
    pos: rtl ? scrollLeft + max : scrollLeft,
    delta: r ? (r.left + r.width / 2) - (b.left + box.clientWidth / 2) : 0,
    fully: r ? r.left >= b.left && r.right <= b.right : true,
    set: first && twin ? Math.abs(twin.getBoundingClientRect().left - first.getBoundingClientRect().left) : 0,
    scrollLeft,
    hasItems: items.length > 0,
    hasSel: Boolean(sel),
    view: box.clientWidth,
  }
}

/* one copy's width: from the first real control to the same control in the "after" copy */
function setWidth(box: HTMLElement | null) {
  const first = realItems(box)[0]
  const twin = box?.querySelector<HTMLElement>('[data-loop="after"] > *')
  if (!first || !twin) return 0
  return Math.abs(twin.getBoundingClientRect().left - first.getBoundingClientRect().left)
}

/* scrollLeft is 0..-max in a right-to-left row; work from the physical left */
function physical(box: HTMLElement) {
  const rtl = getComputedStyle(box).direction === 'rtl'
  const max = box.scrollWidth - box.clientWidth
  return { rtl, max, pos: rtl ? box.scrollLeft + max : box.scrollLeft }
}

function wrap(ctx: LoopCtx) {
  if (ctx.quiet.v) return
  const box = ctx.el.value
  if (!box || !ctx.on.value) return
  const { rtl, max, pos } = physical(box)
  const next = loopPosition(pos, setWidth(box))
  if (next !== pos) box.scrollLeft = rtl ? next - max : next
}

function writeScroll(box: HTMLElement, write: number, known: number, quiet: { v: boolean }) {
  if (write === known) return
  quiet.v = true
  box.scrollLeft = write
  quiet.v = false
}

/* visibility, not display: the row keeps its size, so the observer still fires */
function showStrip(box: HTMLElement) {
  if (box.style.visibility === 'hidden') box.style.visibility = ''
}

async function place(ctx: LoopCtx, force: boolean) {
  const box = ctx.el.value
  if (!box || ctx.quiet.v) return
  if (!ctx.opts.enabled()) { ctx.on.value = false; showStrip(box); return }
  const snap = readSnap(box, ctx.opts.selected)
  if (snap.view <= 0) return
  ctx.centred.v = true
  if (!snap.hasItems) { ctx.on.value = false; showStrip(box); return }
  const overflow = stripOverflows(snap.span, snap.view)
  const turningOn = overflow && !ctx.on.value
  if (ctx.on.value !== overflow) ctx.on.value = overflow
  if (turningOn) {
    const write = loopMountScroll(snap, loopPosition)
    ctx.quiet.v = true
    try {
      await nextTick()
      if (ctx.el.value === box) box.scrollLeft = write
    } finally {
      ctx.quiet.v = false
      if (ctx.el.value === box) showStrip(box)
    }
    return
  }
  const write = loopScrollWrite({ ...snap, force }, loopPosition)
  if (write != null) writeScroll(box, write, snap.scrollLeft, ctx.quiet)
  showStrip(box)
}

export function useLoopStrip(el: Ref<HTMLElement | null>, opts: LoopOpts) {
  const on = ref(false)
  let ro: ResizeObserver | null = null
  const centred = { v: false }
  const quiet = { v: false }
  const ctx: LoopCtx = { el, opts, on, centred, quiet }
  const onScroll = () => wrap(ctx)

  onMounted(() => {
    const box = el.value
    if (!box) return
    /* hidden until place() writes the centred scroll; the row keeps its size */
    if (opts.enabled()) box.style.visibility = 'hidden'
    /* inserting the copies must not make the browser anchor-scroll under us */
    box.style.overflowAnchor = 'none'
    box.addEventListener('scroll', onScroll, { passive: true })
    if (typeof ResizeObserver !== 'function') { void place(ctx, true); return }
    ro = new ResizeObserver(() => { void place(ctx, !centred.v) })
    ro.observe(box)
  })
  onBeforeUnmount(() => {
    el.value?.removeEventListener('scroll', onScroll)
    ro?.disconnect()
  })
  watch([opts.enabled, opts.watchKey], () => { void nextTick(() => place(ctx, false)) })

  return { on, refresh: () => place(ctx, false) }
}
