import type { Ref } from 'vue'
import {
  anchorAfterAppend, anchorAfterPrepend, appendedCount, distanceFromBottom, firstVisibleRow, isFreshList,
  layoutTop, NEAR_BOTTOM_PX, NEAR_TOP_PX, prependedCount, scrollerOf,
} from '~/utils/scroll-anchor.mjs'

/**
 * 013 US7 FR-012: a newest-first feed keeps the reader's place when rows are
 * prepended while they are scrolled down, and counts them in a "new" pill.
 * `root` sits inside the feed; the scroller is the feed list (`.feed-body`),
 * not the document. `keys` are the rendered row keys in DOM order,
 * each row rendered with `data-key`; `isOwn(key)` marks our
 * own send, which jumps to the newest end. `enabled` false is a thread: a new
 * row does not move scrollTop, and nothing scrolls that pane back.
 *
 * `newestLast` true (Settings -> Behaviour "Message order", topic c6994436)
 * mirrors it: the feed opens at its bottom, a reader at the bottom follows new
 * rows (and late height changes: markdown, pictures, the card clip mode, the
 * phone keyboard), a reader scrolled up keeps the row they look at while
 * older pages load above and new rows are counted in a "↓ N new" pill.
 */
export function useScrollAnchor(
  root: Ref<HTMLElement | null>,
  keys: () => string[],
  isOwn: (key: string) => boolean = () => false,
  enabled: () => boolean = () => true,
  newestLast: () => boolean = () => false,
) {
  const pill = ref(0)
  let before: { el: HTMLElement, top: number, height: number, key: string, y: number | null, atBottom: boolean } | null = null
  let listening = false
  /* newest last: the reader is glued to the bottom (last known from a scroll) */
  let stuck = true
  let resize: ResizeObserver | null = null
  let watched: HTMLElement | null = null

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
    if (newestLast()) observe(s)
    return s
  }

  /** viewport y of the scroller's top edge (the page: 0) */
  function edge(s: HTMLElement) {
    return s === document.scrollingElement ? 0 : s.getBoundingClientRect().top
  }

  function fromBottom(s: HTMLElement) {
    return distanceFromBottom({ top: s.scrollTop, height: s.scrollHeight, client: s.clientHeight })
  }

  function onScroll(ev?: Event) {
    if (newestLast()) {
      const s = el()
      if (!s || (ev && ev.target !== s && !(s === document.scrollingElement && ev.target === document))) return
      stuck = fromBottom(s) <= NEAR_BOTTOM_PX
      if (stuck) pill.value = 0
      return
    }
    if (!pill.value) return
    const s = el()
    if (s && s.scrollTop <= NEAR_TOP_PX) pill.value = 0
  }

  /* newest last: content or scroller height changed while glued to the bottom */
  function observe(s: HTMLElement) {
    if (typeof ResizeObserver === 'undefined') return
    if (!resize) resize = new ResizeObserver(() => { if (stuck && newestLast() && enabled()) toBottom() })
    if (watched === s) return
    resize.disconnect()
    watched = s
    resize.observe(s)
    if (root.value) resize.observe(root.value)
  }

  function toBottom(smooth = false) {
    const s = el()
    if (!s) return
    stuck = true
    s.scrollTo({ top: s.scrollHeight, behavior: smooth && !reduced() ? 'smooth' : 'auto' })
  }

  function reduced() {
    return typeof window !== 'undefined' && window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }

  function jump() {
    if (!enabled()) return
    pill.value = 0
    if (newestLast()) {
      toBottom(true)
      return
    }
    const s = el()
    if (s) s.scrollTo({ top: 0, behavior: reduced() ? 'auto' : 'smooth' })
  }

  /** A deep link moved the view to one row: stop following the bottom. */
  function hold() {
    stuck = false
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
    before = {
      el: s, top: s.scrollTop, height: s.scrollHeight, key: row ? String(row.getAttribute('data-key')) : '',
      y: row ? layoutTop(row as HTMLElement) : null, atBottom: stuck && fromBottom(s) <= NEAR_BOTTOM_PX,
    }
  }, { flush: 'pre' })

  /* after it: hold the visible rows in place, or jump for our own send */
  watch(keys, (next, prev) => {
    if (!enabled()) {
      before = null
      return
    }
    const b = before
    before = null
    if (newestLast()) {
      afterAppend(b, prev || [], next || [])
      return
    }
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

  function afterAppend(b: typeof before, prev: string[], next: string[]) {
    if (isFreshList(prev, next)) {
      pill.value = 0
      toBottom()
      return
    }
    if (!b) return
    const added = appendedCount(prev, next)
    const row = b.key && root.value ? root.value.querySelector(`[data-key="${CSS.escape(b.key)}"]`) : null
    const r = anchorAfterAppend({
      top: b.top, atBottom: b.atBottom, own: next.slice(next.length - added).some(isOwn), added, pill: pill.value,
      anchorBefore: b.y, anchorAfter: row && b.y !== null ? layoutTop(row as HTMLElement) : null,
    })
    pill.value = r.pill
    if (r.bottom) toBottom()
    else if (r.top !== b.top) b.el.scrollTop = r.top
  }

  /* the setting flipped while this feed is open: land at the newest end */
  watch(newestLast, (on) => {
    pill.value = 0
    before = null
    if (!on) {
      resize?.disconnect()
      watched = null
    }
    void nextTick(() => {
      if (!enabled()) return
      if (on) toBottom()
      else el()?.scrollTo({ top: 0 })
    })
  })

  onMounted(() => {
    if (newestLast() && keys().length) void nextTick(() => toBottom())
  })

  onUnmounted(() => {
    if (listening) document.removeEventListener('scroll', onScroll, { capture: true })
    resize?.disconnect()
  })

  return { pill, jump, hold }
}
