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
 * `selected` is a selector for the current control; it is brought into view
 * (centred) on mount, on a resize and whenever `watchKey` changes.
 */
export function useLoopStrip(el: Ref<HTMLElement | null>, opts: { enabled: () => boolean, selected: string, watchKey: () => unknown }) {
  const on = ref(false)
  let ro: ResizeObserver | null = null

  const realItems = () => [...(el.value?.querySelectorAll<HTMLElement>(':scope > .sidebar-rail__tabs > .sidebar-tab, :scope > .sidebar-rail__help, :scope > .sidebar-rail__docs, :scope > .sidebar-rail__settings') || [])]

  /** do the real controls overflow the row (measured without the copies) */
  function measure() {
    const box = el.value
    if (!box || !opts.enabled()) { on.value = false; return }
    const items = realItems()
    if (!items.length) { on.value = false; return }
    const rects = items.map((i) => i.getBoundingClientRect())
    const span = Math.max(...rects.map((r) => r.right)) - Math.min(...rects.map((r) => r.left))
    on.value = span > box.clientWidth + 1
  }

  /** one copy's width: from the first real control to the same control in the "after" copy */
  function setWidth() {
    const box = el.value
    const first = realItems()[0]
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

  function wrap() {
    const box = el.value
    if (!box || !on.value) return
    const { rtl, max, pos } = physical(box)
    const next = loopPosition(pos, setWidth())
    if (next !== pos) box.scrollLeft = rtl ? next - max : next
  }

  /** centre the current control when it is not fully in view */
  function reveal(force = false) {
    const box = el.value
    const sel = box?.querySelector<HTMLElement>(opts.selected)
    if (!box || !sel) return
    const b = box.getBoundingClientRect()
    const r = sel.getBoundingClientRect()
    if (!force && r.left >= b.left && r.right <= b.right) return
    box.scrollLeft += (r.left + r.width / 2) - (b.left + box.clientWidth / 2)
    wrap()
  }

  async function refresh(force = false) {
    measure()
    await nextTick()
    reveal(force)
  }

  onMounted(() => {
    const box = el.value
    if (!box) return
    box.addEventListener('scroll', wrap, { passive: true })
    if (typeof ResizeObserver === 'function') {
      ro = new ResizeObserver(() => { void refresh() })
      ro.observe(box)
    }
    void refresh(true)
  })
  onBeforeUnmount(() => {
    el.value?.removeEventListener('scroll', wrap)
    ro?.disconnect()
  })
  watch([opts.enabled, opts.watchKey], () => { void nextTick(() => refresh()) })

  return { on, refresh }
}
