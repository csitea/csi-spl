import type { Ref } from 'vue'
import {
  anchorAfterAppend, anchorAfterPrepend, appendPlan, distanceFromBottom, firstVisibleRow,
  layoutTop, NEAR_BOTTOM_PX, NEAR_TOP_PX, patchStep, prependPlan, scrollerOf,
} from '~/utils/scroll-anchor.mjs'

/** where the reader was, read before the DOM patch */
interface Before { el: HTMLElement, top: number, height: number, key: string, y: number | null, atBottom: boolean }

/** one feed's anchor: its inputs and the state its steps share */
interface Anchor {
  root: Ref<HTMLElement | null>
  isOwn: (key: string) => boolean
  enabled: () => boolean
  newestLast: () => boolean
  pill: Ref<number>
  before: Before | null
  listening: boolean
  /* newest last: the reader is glued to the bottom (last known from a scroll) */
  stuck: boolean
  lastTop: number
  resize: ResizeObserver | null
  watched: HTMLElement | null
  /* the rows observed one by one (see observeRows) */
  rows: Set<Element>
  frame: number
  /* the document scroll listener, one function so it can be removed */
  onScroll: (ev?: Event) => void
}

function scroller(a: Anchor): HTMLElement | null {
  const { enabled, root } = a
  if (!enabled()) return null
  const r = root.value
  if (!r || typeof document === 'undefined') return null
  const s = scrollerOf(r) as HTMLElement
  /* the browser's own scroll anchoring would move it a second time */
  s.style.overflowAnchor = 'none'
  if (!a.listening) {
    /* scroll does not bubble; a capturing listener sees the feed and the page */
    document.addEventListener('scroll', a.onScroll, { capture: true, passive: true })
    a.listening = true
  }
  if (a.newestLast()) observe(a, s)
  return s
}

/** viewport y of the scroller's top edge (the page: 0) */
function edge(s: HTMLElement) {
  return s === document.scrollingElement ? 0 : s.getBoundingClientRect().top
}

function fromBottom(s: HTMLElement) {
  return distanceFromBottom({ top: s.scrollTop, height: s.scrollHeight, client: s.clientHeight })
}

function onScroll(a: Anchor, ev?: Event) {
  if (a.newestLast()) {
    const s = scroller(a)
    if (!s || (ev && ev.target !== s && !(s === document.scrollingElement && ev.target === document))) return
    followScroll(a, s)
    return
  }
  if (!a.pill.value) return
  const s = scroller(a)
  if (s && s.scrollTop <= NEAR_TOP_PX) a.pill.value = 0
}

/* Only the reader scrolling UP lets go of the bottom. Content that grows
   (markdown, pictures, the Omnibox dock padding) fires scroll events far
   from the bottom too, but never moves scrollTop up (measured live on
   prd e2e: +203 px of late height read as "scrolled away"). */
function followScroll(a: Anchor, s: HTMLElement) {
  const top = s.scrollTop
  const { lastTop } = a
  let { stuck } = a
  if (fromBottom(s) <= NEAR_BOTTOM_PX) stuck = true
  else if (top < lastTop - 1) stuck = false
  a.stuck = stuck
  a.lastTop = top
  if (stuck) a.pill.value = 0
}

/* newest last: content or scroller height changed while glued to the bottom */
function observe(a: Anchor, s: HTMLElement) {
  if (typeof ResizeObserver === 'undefined') return
  /* Scrolling INSIDE the callback changes layout in the same frame, which the
     browser reports as a window error ("ResizeObserver loop completed with
     undelivered notifications") and the error snackbar showed it on prd e2e.
     The next animation frame is outside the observer's delivery loop. */
  if (!a.resize) {
    a.resize = new ResizeObserver(() => {
      if (a.frame || !a.stuck || !a.newestLast() || !a.enabled()) return
      a.frame = requestAnimationFrame(() => {
        a.frame = 0
        if (a.stuck && a.newestLast() && a.enabled()) toBottom(a)
      })
    })
  }
  if (a.watched === s) return
  a.resize.disconnect()
  a.rows.clear()
  a.watched = s
  a.resize.observe(s)
  if (a.root.value) a.resize.observe(a.root.value)
  observeRows(a)
}

/* SPL-1762: each row too, not only the list. A card off screen is laid out
   at its contain-intrinsic-size estimate (content-visibility: auto) and grows
   once drawn. When a live frame drops rows at the top as it adds them at the
   bottom, the list can end the frame at the height it had before, so an
   observer on the list alone never fires and the feed stays short of the
   new bottom (message-order A5). A row that grows always fires its own. */
function observeRows(a: Anchor) {
  const ro = a.resize
  const r = a.root.value
  if (!ro || !r) return
  for (const el of a.rows) {
    if (!el.isConnected) {
      ro.unobserve(el)
      a.rows.delete(el)
    }
  }
  for (const el of r.querySelectorAll('[data-key]')) {
    if (a.rows.has(el)) continue
    a.rows.add(el)
    ro.observe(el)
  }
}

function toBottom(a: Anchor, smooth = false) {
  const s = scroller(a)
  if (!s) return
  a.stuck = true
  s.scrollTo({ top: s.scrollHeight, behavior: smooth && !reduced() ? 'smooth' : 'auto' })
  a.lastTop = s.scrollTop
}

function reduced() {
  return typeof window !== 'undefined' && window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

function jump(a: Anchor) {
  if (!a.enabled()) return
  a.pill.value = 0
  if (a.newestLast()) {
    toBottom(a, true)
    return
  }
  const s = scroller(a)
  if (s) s.scrollTo({ top: 0, behavior: reduced() ? 'auto' : 'smooth' })
}

/* before the DOM patch: where the reader is */
function capture(a: Anchor) {
  const s = a.enabled() ? scroller(a) : null
  if (!s) {
    a.before = null
    return
  }
  /* a scroll UP whose event has not been delivered yet (a wheel, then a click
     on Load more in the same frame) already left the bottom */
  if (a.newestLast() && a.stuck && s.scrollTop < a.lastTop - 1 && fromBottom(s) > NEAR_BOTTOM_PX) a.stuck = false
  const row = firstVisibleRow(a.root.value, edge(s))
  a.before = {
    el: s, top: s.scrollTop, height: s.scrollHeight, key: row ? String(row.getAttribute('data-key')) : '',
    y: row ? layoutTop(row as HTMLElement) : null, atBottom: a.stuck,
  }
}

/** the anchor row's layout top now, when it was seen before the patch */
function anchorNow(a: Anchor, b: Before) {
  const row = b.key && a.root.value ? a.root.value.querySelector(`[data-key="${CSS.escape(b.key)}"]`) : null
  return row && b.y !== null ? layoutTop(row as HTMLElement) : null
}

/* after it: hold the visible rows in place, or jump for our own send */
function afterPatch(a: Anchor, next: string[], prev: string[]) {
  const b = a.before
  a.before = null
  const on = a.enabled()
  const step = patchStep({ enabled: on, newestLast: on && a.newestLast(), captured: b !== null })
  if (step === 'append') {
    observeRows(a)
    afterAppend(a, b, prev, next)
  } else if (step === 'prepend' && b) afterPrepend(a, b, prev, next)
}

function afterPrepend(a: Anchor, b: Before, prev: string[], next: string[]) {
  const s = b.el
  const { step, added } = prependPlan(prev, next, a.isOwn)
  if (step === 'none') return
  if (step === 'jump') {
    jump(a)
    return
  }
  const r = anchorAfterPrepend({
    top: b.top, prevHeight: b.height, nextHeight: s.scrollHeight, added, pill: a.pill.value,
    anchorBefore: b.y, anchorAfter: anchorNow(a, b),
  })
  if (r.moved) s.scrollTop = r.top
  a.pill.value = r.pill
}

function afterAppend(a: Anchor, b: Before | null, prev: string[], next: string[]) {
  const { step, added, own } = appendPlan(prev, next, a.isOwn)
  if (step === 'bottom') {
    a.pill.value = 0
    toBottom(a)
    return
  }
  if (!b) return
  const r = anchorAfterAppend({
    top: b.top, atBottom: b.atBottom, own, added, pill: a.pill.value,
    anchorBefore: b.y, anchorAfter: anchorNow(a, b),
  })
  a.pill.value = r.pill
  if (r.bottom) toBottom(a)
  else if (r.top !== b.top) b.el.scrollTop = r.top
}

/* the setting flipped while this feed is open: land at the newest end */
function flipOrder(a: Anchor, on: boolean) {
  a.pill.value = 0
  a.before = null
  if (!on) {
    a.resize?.disconnect()
    a.watched = null
    a.rows.clear()
  }
  void nextTick(() => {
    if (!a.enabled()) return
    if (on) toBottom(a)
    else scroller(a)?.scrollTo({ top: 0 })
  })
}

function teardown(a: Anchor) {
  if (a.listening) document.removeEventListener('scroll', a.onScroll, { capture: true })
  a.resize?.disconnect()
  a.rows.clear()
  if (a.frame) cancelAnimationFrame(a.frame)
}

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
  const a: Anchor = {
    root, isOwn, enabled, newestLast, pill: ref(0), before: null, listening: false,
    stuck: true, lastTop: 0, resize: null, watched: null, rows: new Set(), frame: 0, onScroll: () => {},
  }
  a.onScroll = (ev?: Event) => onScroll(a, ev)

  watch(keys, () => capture(a), { flush: 'pre' })
  watch(keys, (next, prev) => afterPatch(a, next || [], prev || []), { flush: 'post' })
  watch(newestLast, on => flipOrder(a, on))

  onMounted(() => {
    if (newestLast() && keys().length) void nextTick(() => toBottom(a))
  })
  onUnmounted(() => teardown(a))

  /** A deep link moved the view to one row: stop following the bottom. */
  function hold() {
    a.stuck = false
  }

  return { pill: a.pill, jump: () => jump(a), hold }
}
