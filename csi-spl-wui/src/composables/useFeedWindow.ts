import type { Ref, ShallowRef } from 'vue'
import { EST_ROW_PX, OVERSCAN_PX, VIRTUAL_MIN, estimateOf, feedRange, offsetOf, rowSizes, slotHeights } from '~/utils/feed-virtual.mjs'

/** What a draw request asks for: a topic's card or one message. */
interface FeedAsk { taskId?: string, msgId?: string }
/** The event parent-section-open's revealCard sends for a ?topic= card it cannot find. */
const FEED_DRAW_EVENT = 'spool:feed-reveal'
const READER_INPUTS = ['wheel', 'touchstart', 'pointerdown', 'keydown']

type Row = { key: string, msg?: { task_id?: unknown, msg_id?: unknown } }
type Range = { start: number, end: number }

interface Opts<T extends Row> {
  /** every row of the feed, in DOM order */
  items: () => T[]
  /** the host windows this feed (the channel feed, MessageFeed) */
  on: () => boolean
  /** the feed's own element; its .feed-body ancestor is the scroller */
  root: Ref<HTMLElement | null>
}

/* The state one feed's window keeps; the steps below read and write it. */
interface Win<T extends Row> {
  o: Opts<T>
  windowed: Readonly<Ref<boolean>>
  range: ShallowRef<Range | null>
  drawn: () => T[]
  heights: Map<string, number>
  /** what a row not measured yet counts, taken once from the first rows measured (0 = not yet) */
  est: number
  top: HTMLElement | null
  bottom: HTMLElement | null
  /** the row a draw request pinned, until the reader moves the pane */
  pin: string
}

function holds(it: Row, want: FeedAsk) {
  if (!it.msg) return false
  return want.taskId ? String(it.msg.task_id || '') === want.taskId : String(it.msg.msg_id || '') === String(want.msgId || '')
}
function scrollerOf<T extends Row>(w: Win<T>): HTMLElement | null {
  return w.o.root.value?.closest<HTMLElement>('.feed-body') || null
}
function rowsEl<T extends Row>(w: Win<T>): HTMLElement | null {
  return w.o.root.value?.querySelector<HTMLElement>('.live-rows') || null
}

/* each drawn row's slot height, by key (the rows are the list's children) */
function measure<T extends Row>(w: Win<T>) {
  const list = rowsEl(w)
  const drawn = w.drawn()
  if (!list || list.children.length !== drawn.length) return
  const els = [...list.children] as HTMLElement[]
  const slots = slotHeights(els.map((e) => e.offsetTop), els.map((e) => e.offsetHeight))
  slots.forEach((h, i) => { if (h > 0) w.heights.set(drawn[i].key, h) })
  if (!w.est && w.heights.size) w.est = estimateOf(w.heights)
}

/* The rows a redraw puts above the viewport that had no measured height
   yet: each counted as the estimate in the spacer math. */
function guessedAbove<T extends Row>(w: Win<T>, keys: string[], sizes: number[], from: number, viewTop: number) {
  const out: string[] = []
  let y = offsetOf(sizes, from)
  for (let i = from; i < keys.length && y + sizes[i] <= viewTop; i++) {
    if (!w.heights.has(keys[i])) out.push(keys[i])
    y += sizes[i]
  }
  return out
}
/* Once those rows are drawn and measured, move the pane by what they
   turned out taller or shorter than guessed, so the rows on screen stay.
   Every other row above is measured, so the spacer math is exact there. */
function settle<T extends Row>(w: Win<T>, s: HTMLElement, guessed: string[], est: number) {
  let d = 0
  for (const k of guessed) d += (w.heights.get(k) ?? est) - est
  if (Math.abs(d) >= 1) s.scrollTop += d
}

/* the viewport in row coordinates (0 = the top of the first row); a pinned
   row off screen moves the window to it */
function viewOf<T extends Row>(w: Win<T>, s: HTMLElement, origin: HTMLElement, keys: string[], sizes: number[]) {
  const zero = origin.getBoundingClientRect().top - s.getBoundingClientRect().top + s.scrollTop
  const viewTop = s.scrollTop - zero
  const viewBottom = viewTop + s.clientHeight
  const at = w.pin ? keys.indexOf(w.pin) : -1
  if (at < 0) return { viewTop, viewBottom }
  const y = offsetOf(sizes, at)
  if (y >= viewTop - OVERSCAN_PX && y <= viewBottom + OVERSCAN_PX) return { viewTop, viewBottom }
  return { viewTop: y, viewBottom: y + s.clientHeight }
}

/* spacer heights go through the CSSOM, never a :style binding (CSP) */
function setSpacers<T extends Row>(w: Win<T>, top: number, bottom: number) {
  if (w.top) w.top.style.height = `${Math.round(top)}px`
  if (w.bottom) w.bottom.style.height = `${Math.round(bottom)}px`
}

/* measure what is drawn, pick the rows for the viewport, keep the row on screen in place */
function update<T extends Row>(w: Win<T>, follow: (s: HTMLElement) => void) {
  if (!w.windowed.value) {
    if (w.range.value) w.range.value = null
    return
  }
  const s = scrollerOf(w)
  if (!s || !w.top) return
  follow(s)
  measure(w)
  const keys = w.o.items().map((it) => it.key)
  const sizes = rowSizes(keys, w.heights, w.est || undefined)
  const view = viewOf(w, s, w.top, keys, sizes)
  const next = feedRange({ sizes, ...view })
  const cur = w.range.value
  setSpacers(w, next.top, next.bottom)
  if (cur && cur.start === next.start && cur.end === next.end) return
  const guessed = guessedAbove(w, keys, sizes, next.start, view.viewTop)
  const est = w.est || EST_ROW_PX
  w.range.value = { start: next.start, end: next.end }
  void nextTick(() => {
    measure(w)
    settle(w, s, guessed, est)
  })
}

/* redraw on scroll and on a size change; the reader's own input drops the pin */
function scrollWatch<T extends Row>(w: Win<T>, schedule: () => void) {
  let watched: HTMLElement | null = null
  let resize: ResizeObserver | null = null
  const unpin = () => { w.pin = '' }
  function stop() {
    if (!watched) return
    watched.removeEventListener('scroll', schedule)
    for (const t of READER_INPUTS) watched.removeEventListener(t, unpin)
    resize?.disconnect()
    resize = null
    watched = null
  }
  function follow(s: HTMLElement) {
    if (watched === s) return
    stop()
    watched = s
    s.addEventListener('scroll', schedule, { passive: true })
    for (const t of READER_INPUTS) s.addEventListener(t, unpin, { passive: true })
    if (typeof ResizeObserver === 'undefined') return
    resize = new ResizeObserver(() => schedule())
    resize.observe(s)
    const list = rowsEl(w)
    if (list) resize.observe(list)
  }
  return { follow, stop }
}

/**
 * SPL-2146: draw only the rows near the viewport (utils/feed-virtual.mjs says
 * why and when). Two spacers stand for the rows not drawn. Every row drawn is
 * measured, so a spacer is the measured heights plus an estimate for rows
 * never drawn; a row drawn above the viewport that turns out taller or
 * shorter than its estimate moves the pane by the difference (settle).
 * drawRow (the unread jump) and a FEED_DRAW_EVENT (a ?topic= link) pin a
 * row: the window is drawn around it until the reader moves the pane.
 */
export function useFeedWindow<T extends Row>(o: Opts<T>) {
  const windowed = computed(() => o.on() && o.items().length >= VIRTUAL_MIN)
  /* null = not measured yet: draw every row once, then window */
  const range = shallowRef<Range | null>(null)
  const drawnItems = computed(() => {
    const all = o.items()
    const r = range.value
    if (!windowed.value || !r) return all
    return all.slice(r.start, Math.max(r.end, r.start + 1))
  })
  const w: Win<T> = { o, windowed, range, drawn: () => drawnItems.value, heights: new Map(), est: 0, top: null, bottom: null, pin: '' }
  let frame = 0
  const schedule = () => {
    if (frame || typeof requestAnimationFrame === 'undefined') return
    frame = requestAnimationFrame(() => { frame = 0; run() })
  }
  const scroll = scrollWatch(w, schedule)
  const run = () => update(w, scroll.follow)

  /** Draw the row `key` (pinned until the reader scrolls), then return find(). */
  async function drawRow<R>(key: string, find: () => R): Promise<R> {
    if (windowed.value && key) {
      w.pin = key
      run()
      await nextTick()
    }
    return find()
  }
  function onAsk(ev: Event) {
    const want = (ev as CustomEvent<FeedAsk>).detail || {}
    const hit = windowed.value ? o.items().find((it) => holds(it, want)) : undefined
    if (hit) void drawRow(hit.key, () => null)
  }

  onMounted(() => {
    /* watched from mount on: a host may declare what items() reads after this call */
    watch([() => o.items(), windowed], () => { void nextTick(run) }, { flush: 'post' })
    document.addEventListener(FEED_DRAW_EVENT, onAsk)
    void nextTick(run)
  })
  onUnmounted(() => {
    document.removeEventListener(FEED_DRAW_EVENT, onAsk)
    if (frame) cancelAnimationFrame(frame)
    scroll.stop()
  })
  /* the spacers' function refs */
  const spacerTop = (el: unknown) => { w.top = el instanceof HTMLElement ? el : null }
  const spacerBottom = (el: unknown) => { w.bottom = el instanceof HTMLElement ? el : null }
  return { drawnItems, windowed, spacerTop, spacerBottom, drawRow }
}
