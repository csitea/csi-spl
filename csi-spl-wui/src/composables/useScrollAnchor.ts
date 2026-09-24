import type { Ref } from 'vue'
import { anchorAfterPrepend, firstVisibleRow, layoutTop, NEAR_TOP_PX, prependedCount, scrollerOf } from '~/utils/scroll-anchor.mjs'

/**
 * 013 US7 FR-012: a newest-first feed keeps the reader's place when rows are
 * prepended while they are scrolled down, and counts them in a "new" pill.
 * `root` sits inside the feed; the scroller is the feed list (`.feed-body`),
 * not the document. `keys` are the rendered row keys,
 * newest first, each row rendered with `data-key`; `isOwn(key)` marks our
 * own send, which jumps to the top. `enabled` false is a thread: a new row
 * does not move scrollTop, and nothing scrolls that pane back.
 */
export function useScrollAnchor(root: Ref<HTMLElement | null>, keys: () => string[], isOwn: (key: string) => boolean = () => false, enabled: () => boolean = () => true) {
  const pill = ref(0)
  let before: { el: HTMLElement, top: number, height: number, key: string, y: number | null } | null = null
  let listening = false

  function el(): HTMLElement | null {
    if (!enabled()) return null
    const r = root.value
    if (!r || typeof document === 'undefined') return null
    const s = scrollerOf(r) as HTMLElement
    /* the browser's own scroll anchoring would move it a second time */
    s.style.overflowAnchor = 'none'
    if (!listening) {
      /* scroll does not bubble; a capturing listener sees the feed and the page */
      document.addEventListener('scroll', onScroll, { capture: true, passive: true })
      listening = true
    }
    return s
  }

  /** viewport y of the scroller's top edge (the page: 0) */
  function edge(s: HTMLElement) {
    return s === document.scrollingElement ? 0 : s.getBoundingClientRect().top
  }

  function onScroll() {
    if (!pill.value) return
    const s = el()
    if (s && s.scrollTop <= NEAR_TOP_PX) pill.value = 0
  }

  function reduced() {
    return typeof window !== 'undefined' && window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }

  function jump() {
    if (!enabled()) return
    pill.value = 0
    const s = el()
    if (s) s.scrollTo({ top: 0, behavior: reduced() ? 'auto' : 'smooth' })
  }

  /* before the DOM patch: where the reader is */
  watch(keys, () => {
    if (!enabled()) {
      before = null
      return
    }
    const s = el()
    if (!s) {
      before = null
      return
    }
    const row = firstVisibleRow(root.value, edge(s))
    before = { el: s, top: s.scrollTop, height: s.scrollHeight, key: row ? String(row.getAttribute('data-key')) : '', y: row ? layoutTop(row as HTMLElement) : null }
  }, { flush: 'pre' })

  /* after it: hold the visible rows in place, or jump for our own send */
  watch(keys, (next, prev) => {
    if (!enabled()) {
      before = null
      return
    }
    const b = before
    before = null
    if (!b) return
    const s = b.el
    const added = prependedCount(prev || [], next || [])
    if (!added) return
    if ((next || []).slice(0, added).some(isOwn)) {
      jump()
      return
    }
    const row = b.key && root.value ? root.value.querySelector(`[data-key="${CSS.escape(b.key)}"]`) : null
    const r = anchorAfterPrepend({
      top: b.top, prevHeight: b.height, nextHeight: s.scrollHeight, added, pill: pill.value,
      anchorBefore: b.y, anchorAfter: row && b.y !== null ? layoutTop(row as HTMLElement) : null,
    })
    if (r.moved) s.scrollTop = r.top
    pill.value = r.pill
  }, { flush: 'post' })

  onUnmounted(() => {
    if (listening) document.removeEventListener('scroll', onScroll, { capture: true })
  })

  return { pill, jump }
}
