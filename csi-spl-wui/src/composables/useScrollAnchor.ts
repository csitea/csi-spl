import type { Ref } from 'vue'
import { anchorAfterPrepend, NEAR_TOP_PX, prependedCount } from '~/utils/scroll-anchor.mjs'

/**
 * 013 US7 FR-012: a newest-first feed keeps the reader's place when rows are
 * prepended while they are scrolled down, and counts them in a "new" pill.
 * `root` sits inside the scrolling `.feed-body`; `keys` are the rendered row
 * keys, newest first; `isOwn(key)` marks our own send, which jumps to the top.
 */
export function useScrollAnchor(root: Ref<HTMLElement | null>, keys: () => string[], isOwn: (key: string) => boolean = () => false) {
  const pill = ref(0)
  let scroller: HTMLElement | null = null
  let before: { top: number, height: number } | null = null

  function el(): HTMLElement | null {
    if (scroller && scroller.isConnected) return scroller
    const r = root.value
    scroller = r ? (r.closest('.feed-body') as HTMLElement | null) || r.parentElement : null
    /* the browser's own scroll anchoring would move it a second time */
    if (scroller) scroller.style.overflowAnchor = 'none'
    if (scroller) scroller.addEventListener('scroll', onScroll, { passive: true })
    return scroller
  }

  function onScroll() {
    if (scroller && scroller.scrollTop <= NEAR_TOP_PX) pill.value = 0
  }

  function reduced() {
    return typeof window !== 'undefined' && window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }

  function jump() {
    pill.value = 0
    const s = el()
    if (s) s.scrollTo({ top: 0, behavior: reduced() ? 'auto' : 'smooth' })
  }

  /* before the DOM patch: where the reader is */
  watch(keys, () => {
    const s = el()
    before = s ? { top: s.scrollTop, height: s.scrollHeight } : null
  }, { flush: 'pre' })

  /* after it: hold the visible rows in place, or jump for our own send */
  watch(keys, (next, prev) => {
    const s = el()
    const b = before
    before = null
    if (!s || !b) return
    const added = prependedCount(prev || [], next || [])
    if (!added) return
    if ((next || []).slice(0, added).some(isOwn)) {
      jump()
      return
    }
    const r = anchorAfterPrepend({ top: b.top, prevHeight: b.height, nextHeight: s.scrollHeight, added, pill: pill.value })
    if (r.moved) s.scrollTop = r.top
    pill.value = r.pill
  }, { flush: 'post' })

  onUnmounted(() => {
    if (scroller) scroller.removeEventListener('scroll', onScroll)
  })

  return { pill, jump }
}
