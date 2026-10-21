import type { Ref } from 'vue'
import { threadJumpState } from '~/utils/thread-jump.mjs'

/**
 * LiveFeed's phone thread arrow (thread-jump.mjs): which end of the thread
 * the round button takes the reader to, and the tap that goes there.
 *
 * Phone thread. The scroller is the pane's .feed-body. A channel feed never
 * passes holdScroll, and a desktop is not phone, so this stays empty there.
 */
export function useLiveFeedThreadEnds(o: {
  root: Ref<HTMLElement | null>
  phone: Ref<boolean>
  newestLast: Ref<boolean>
  holdScroll: () => boolean | undefined
  rowCount: () => number
}) {
  const { root, phone, newestLast } = o
  const jumpEnds = ref(threadJumpState())
  /* The phone pane is display:none until the stack shows it, so the first
     measure sees clientHeight 0. A size change (the pane appearing, the
     keyboard, a late picture) measures again. It never asks for another page. */
  let jumpResize: ResizeObserver | null = null
  let jumpWatched: HTMLElement | null = null
  function watchJumpSize(s: HTMLElement) {
    if (typeof ResizeObserver === 'undefined') return
    if (!jumpResize) jumpResize = new ResizeObserver(() => measureJump())
    if (jumpWatched === s) return
    jumpResize.disconnect()
    jumpWatched = s
    jumpResize.observe(s)
  }
  function measureJump() {
    if (!phone.value || o.holdScroll() !== true) {
      if (jumpEnds.value.show) jumpEnds.value = threadJumpState()
      jumpResize?.disconnect()
      jumpWatched = null
      return
    }
    const s = root.value?.closest<HTMLElement>('.feed-body')
    if (!s) return
    watchJumpSize(s)
    const next = threadJumpState({
      scrollTop: s.scrollTop,
      scrollHeight: s.scrollHeight,
      clientHeight: s.clientHeight,
      newestLast: newestLast.value,
    })
    const cur = jumpEnds.value
    if (cur.show !== next.show || cur.dir !== next.dir || cur.top !== next.top) jumpEnds.value = next
  }
  function jumpThreadEnd() {
    const s = root.value?.closest<HTMLElement>('.feed-body')
    const st = jumpEnds.value
    if (!s || !st.show) return
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    s.scrollTo({ top: st.top, behavior: reduce ? 'auto' : 'smooth' })
  }

  onMounted(() => {
    void nextTick(() => measureJump())
  })
  watch([phone, newestLast, o.holdScroll, o.rowCount], async () => {
    await nextTick()
    measureJump()
  })
  onUnmounted(() => {
    jumpResize?.disconnect()
  })

  return { jumpEnds, measureJump, jumpThreadEnd }
}
